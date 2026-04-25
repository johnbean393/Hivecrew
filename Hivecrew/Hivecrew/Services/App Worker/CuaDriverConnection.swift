//
//  CuaDriverConnection.swift
//  Hivecrew
//
//  AgentToolConnection conformance for the App Worker runtime.
//  Uses CuaDriverCore linked in-process for host macOS GUI control,
//  and provides local shell/file operations via the session sandbox.
//

import Foundation
import AppKit
import CoreGraphics
import HivecrewCore
import CuaDriverCore

// MARK: - Supporting types

struct AppContext: Sendable {
    var pid: Int
    var appName: String
    var bundleId: String?
}

struct WindowContext: Sendable {
    var windowId: Int
    var title: String
    var pid: Int
}

struct AXElementSummary: Sendable {
    var index: Int
    var role: String
    var label: String
    var value: String?
}

struct AppSummary: Sendable {
    var pid: Int
    var name: String
    var bundleId: String?
}

struct WindowSummary: Sendable {
    var windowId: Int
    var title: String
    var pid: Int
    var appName: String? = nil
}

struct WindowStateSnapshot: Sendable {
    var treeMarkdown: String
    var elementCount: Int
    var screenshotBase64: String?
    var screenWidth: Int?
    var screenHeight: Int?
}

// MARK: - CuaDriverConnection

@MainActor
final class CuaDriverConnection: AgentToolConnection {
    let runtimeKind: AgentRuntimeKind = .app
    let capabilities: RuntimeCapabilities = .app

    let connectionId: String
    let session: AppWorkerSession
    weak var todoManager: TodoManager?

    let engine: AppStateEngine
    let capture: WindowCapture
    let focusGuard: FocusGuard

    var currentApp: AppContext?
    var currentWindow: WindowContext?
    var elementCache: [Int: AXElementSummary] = [:]
    var cachedLaunchWindows: (pid: Int, windows: [WindowSummary])?

    var lockedAppKeys: Set<String> = []

    init(session: AppWorkerSession, engine: AppStateEngine, capture: WindowCapture, focusGuard: FocusGuard, todoManager: TodoManager? = nil) {
        self.connectionId = UUID().uuidString
        self.session = session
        self.engine = engine
        self.capture = capture
        self.focusGuard = focusGuard
        self.todoManager = todoManager
    }

    // MARK: - Observation

    func screenshot() async throws -> ScreenshotResult? {
        guard let window = currentWindow else { return nil }
        do {
            let shot = try await capture.captureWindow(
                windowID: CGWindowID(window.windowId),
                format: .png,
                quality: 80
            )
            return ScreenshotResult(
                imageBase64: shot.imageData.base64EncodedString(),
                width: shot.width,
                height: shot.height
            )
        } catch {
            return nil
        }
    }

    func observe() async throws -> RuntimeObservation {
        guard let window = currentWindow else {
            var obs = session.textObservation(todoManager: todoManager)
            obs.text += "\n\nNo app/window selected. Use app_list_apps to discover running apps, then open_app and app_list_windows to target a window."
            return obs
        }

        let state = try await getWindowState()

        var lines: [String] = []
        lines.append("Runtime: App Worker (host macOS GUI)")
        lines.append("Current app: \(currentApp?.appName ?? "unknown") (pid: \(window.pid))")
        lines.append("Current window: \(window.title) (id: \(window.windowId))")
        lines.append("")
        lines.append("Accessible elements (\(state.elementCount) interactive):")
        lines.append(state.treeMarkdown)

        var screenshot: ScreenshotResult?
        if let base64 = state.screenshotBase64 {
            screenshot = ScreenshotResult(
                imageBase64: base64,
                width: state.screenWidth ?? 0,
                height: state.screenHeight ?? 0
            )
        }

        return RuntimeObservation(
            text: lines.joined(separator: "\n"),
            screenshot: screenshot,
            screenWidth: state.screenWidth,
            screenHeight: state.screenHeight,
            metadata: [
                "runtime": "app",
                "pid": "\(window.pid)",
                "window_id": "\(window.windowId)"
            ]
        )
    }

    // MARK: - App/File/URL

    func openApp(bundleId: String?, appName: String?) async throws {
        let appKey = AppFocusManager.normalizedKey(bundleId: bundleId, appName: appName)
        await AppFocusManager.shared.acquire(appKey: appKey, connectionId: connectionId)
        lockedAppKeys.insert(appKey)

        guard bundleId != nil || appName != nil else {
            throw CuaDriverError.toolCallFailed("Provide either bundle_id or name.")
        }

        let previousFrontmost = NSWorkspace.shared.frontmostApplication

        let running = NSWorkspace.shared.runningApplications.first { app in
            if let bid = bundleId, !bid.isEmpty, app.bundleIdentifier == bid { return true }
            if let name = appName, !name.isEmpty,
               app.localizedName?.localizedCaseInsensitiveCompare(name) == .orderedSame { return true }
            return false
        }

        let pid: Int
        let resolvedName: String
        let resolvedBundleId: String?

        if let app = running {
            pid = Int(app.processIdentifier)
            resolvedName = app.localizedName ?? appName ?? "app"
            resolvedBundleId = app.bundleIdentifier ?? bundleId
        } else {
            var appURL: URL?
            if let bid = bundleId, !bid.isEmpty {
                appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid)
            }
            if appURL == nil, let name = appName, !name.isEmpty {
                for dir in ["/System/Applications", "/Applications", "/System/Applications/Utilities"] {
                    let candidate = URL(fileURLWithPath: "\(dir)/\(name).app")
                    if FileManager.default.fileExists(atPath: candidate.path) {
                        appURL = candidate
                        break
                    }
                }
            }
            guard let url = appURL else {
                throw CuaDriverError.toolCallFailed(
                    "Application not found: \(appName ?? bundleId ?? "unknown")"
                )
            }

            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            let app = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
            pid = Int(app.processIdentifier)
            resolvedName = app.localizedName ?? appName ?? "app"
            resolvedBundleId = app.bundleIdentifier ?? bundleId
            try? await Task.sleep(nanoseconds: 800_000_000)

            // Apps can self-activate during launch (e.g. in
            // applicationDidFinishLaunching) despite activates=false.
            // Restore the user's frontmost app if it was stolen.
            restoreFrontmostIfStolen(previousFrontmost)
        }

        currentApp = AppContext(pid: pid, appName: resolvedName, bundleId: resolvedBundleId)
        elementCache = [:]

        // Use allWindows() so we find windows of background-launched apps that
        // may not be on-screen yet (minimized, other Space, hidden launch).
        let windows = WindowEnumerator.allWindows()
            .filter { $0.pid == Int32(pid) && $0.bounds.width > 1 && $0.bounds.height > 1 }
            .sorted { $0.zIndex > $1.zIndex }
        if !windows.isEmpty {
            let summaries = windows.map { WindowSummary(windowId: $0.id, title: $0.name, pid: Int($0.pid)) }
            cachedLaunchWindows = (pid: pid, windows: summaries)
            if let best = summaries.first {
                currentWindow = WindowContext(windowId: best.windowId, title: best.title, pid: best.pid)
            }
        } else {
            currentWindow = nil
            cachedLaunchWindows = nil
        }
    }

    /// Restores the user's frontmost app if something stole focus.
    private func restoreFrontmostIfStolen(_ previous: NSRunningApplication?) {
        guard let previous else { return }
        let current = NSWorkspace.shared.frontmostApplication
        if let current, current.processIdentifier != previous.processIdentifier {
            previous.activate()
        }
    }

    func openFile(path: String, withApp: String?) async throws {
        let previousFrontmost = NSWorkspace.shared.frontmostApplication
        let url = URL(fileURLWithPath: path)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        if let app = withApp, !app.isEmpty {
            try await NSWorkspace.shared.open(
                [url],
                withApplicationAt: URL(fileURLWithPath: app),
                configuration: config
            )
        } else if let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url) {
            try await NSWorkspace.shared.open(
                [url],
                withApplicationAt: defaultApp,
                configuration: config
            )
        } else {
            throw CuaDriverError.toolCallFailed(
                "No application found to open file: \(path). Specify an app with the withApp parameter."
            )
        }
        restoreFrontmostIfStolen(previousFrontmost)
    }

    func openUrl(_ urlString: String) async throws {
        let urlString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlString.isEmpty else { return }

        let previousFrontmost = NSWorkspace.shared.frontmostApplication
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false

        if urlString.hasPrefix("x-apple.systempreferences:") {
            let bid = "com.apple.systempreferences"
            if let nsUrl = URL(string: urlString),
               let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                try await NSWorkspace.shared.open([nsUrl], withApplicationAt: appURL, configuration: config)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            restoreFrontmostIfStolen(previousFrontmost)
            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bid }) {
                let pid = Int(app.processIdentifier)
                currentApp = AppContext(pid: pid, appName: "System Settings", bundleId: bid)
                elementCache = [:]
                let windows = WindowEnumerator.allWindows()
                    .filter { $0.pid == Int32(pid) && $0.bounds.width > 1 && $0.bounds.height > 1 }
                    .sorted { $0.zIndex > $1.zIndex }
                if let best = windows.first {
                    currentWindow = WindowContext(windowId: best.id, title: best.name, pid: Int(best.pid))
                    cachedLaunchWindows = (pid: pid, windows: windows.map {
                        WindowSummary(windowId: $0.id, title: $0.name, pid: Int($0.pid))
                    })
                } else {
                    currentWindow = nil
                }
            }
            return
        }

        if let nsUrl = URL(string: urlString) {
            NSWorkspace.shared.open(nsUrl, configuration: config) { _, _ in }
            try? await Task.sleep(nanoseconds: 500_000_000)
            restoreFrontmostIfStolen(previousFrontmost)
        }
    }

    // MARK: - Mouse (pixel-level via CuaDriverCore)

    func mouseMove(x: Double, y: Double) async throws {
        guard let window = currentWindow else { throw CuaDriverError.noWindowSelected }
        let screenPoint = try WindowCoordinateSpace.screenPoint(
            fromImagePixel: CGPoint(x: x, y: y),
            forPid: Int32(window.pid),
            windowId: UInt32(window.windowId)
        )
        CursorControl.move(to: screenPoint)
    }

    func mouseClick(x: Double, y: Double, button: String, clickType: String) async throws {
        guard let window = currentWindow else { throw CuaDriverError.noWindowSelected }
        let screenPoint = try WindowCoordinateSpace.screenPoint(
            fromImagePixel: CGPoint(x: x, y: y),
            forPid: Int32(window.pid),
            windowId: UInt32(window.windowId)
        )
        let mouseButton: MouseInput.Button = button == "right" ? .right : .left
        let count = clickType == "double" ? 2 : 1
        try MouseInput.click(
            at: screenPoint,
            toPid: pid_t(window.pid),
            button: mouseButton,
            count: count
        )
    }

    func mouseDrag(fromX: Double, fromY: Double, toX: Double, toY: Double) async throws {
        guard let window = currentWindow else { throw CuaDriverError.noWindowSelected }
        let startScreen = try WindowCoordinateSpace.screenPoint(
            fromImagePixel: CGPoint(x: fromX, y: fromY),
            forPid: Int32(window.pid),
            windowId: UInt32(window.windowId)
        )
        let endScreen = try WindowCoordinateSpace.screenPoint(
            fromImagePixel: CGPoint(x: toX, y: toY),
            forPid: Int32(window.pid),
            windowId: UInt32(window.windowId)
        )
        synthesizeDrag(from: startScreen, to: endScreen, pid: pid_t(window.pid))
    }

    // MARK: - Keyboard (via CuaDriverCore)

    func keyboardType(text: String) async throws {
        guard let window = currentWindow else { throw CuaDriverError.noWindowSelected }
        let pid = pid_t(window.pid)

        // Try AX-based text insertion first (works for native text fields)
        let focused = try? AXInput.focusedElement(pid: pid)
        if let focused = focused {
            try? AXInput.setAttribute("AXSelectedText", on: focused, value: text as CFTypeRef)
            return
        }

        // Fall back to character-by-character typing via CGEvent
        try KeyboardInput.typeCharacters(text, toPid: pid)
    }

    /// Key combinations that macOS intercepts at the system level before
    /// PID-targeted CGEvent delivery, causing app switching or window hiding.
    private static let focusStealingHotkeys: Set<[String]> = [
        ["command", "tab"],
        ["command", "shift", "tab"],
        ["command", "space"],
        ["command", "option", "space"],
        ["command", "h"],
        ["command", "option", "h"],
        ["command", "m"],
        ["command", "q"],
        ["control", "up"],
        ["control", "down"],
        ["control", "left"],
        ["control", "right"],
        ["control", "space"],
        ["globe", "tab"],
    ]

    func keyboardKey(key: String, modifiers: [String]) async throws {
        guard let window = currentWindow else { throw CuaDriverError.noWindowSelected }
        let pid = pid_t(window.pid)

        let filtered = modifiers.filter { !$0.isEmpty }
        if !filtered.isEmpty {
            let normalized = Set((filtered + [key]).map { $0.lowercased() })
            for forbidden in Self.focusStealingHotkeys {
                if normalized == Set(forbidden) {
                    throw CuaDriverError.toolCallFailed(
                        "Key combination \(filtered.joined(separator: "+"))+\(key) "
                        + "is intercepted by macOS and would switch apps or hide windows. "
                        + "Use app_click_element or another approach instead."
                    )
                }
            }
            try KeyboardInput.hotkey(filtered + [key], toPid: pid)
            return
        }
        try KeyboardInput.press(key, toPid: pid)
    }

    func scroll(x: Double, y: Double, deltaX: Double, deltaY: Double) async throws {
        guard let window = currentWindow else { throw CuaDriverError.noWindowSelected }
        let screenPoint = try WindowCoordinateSpace.screenPoint(
            fromImagePixel: CGPoint(x: x, y: y),
            forPid: Int32(window.pid),
            windowId: UInt32(window.windowId)
        )
        synthesizeScroll(at: screenPoint, deltaX: deltaX, deltaY: deltaY, pid: pid_t(window.pid))
    }

    // MARK: - Shell (host-local, rooted at session workspace)

    func runShell(command: String, timeout: Double?) async throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", command]
        process.currentDirectoryURL = session.paths.workspace

        var env = ProcessInfo.processInfo.environment
        env["HOME"] = session.paths.root.path
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        let effectiveTimeout = timeout ?? 120
        let processRef = process
        let timeoutTask = Task.detached {
            try await Task.sleep(nanoseconds: UInt64(effectiveTimeout * 1_000_000_000))
            if processRef.isRunning { processRef.terminate() }
        }

        process.waitUntilExit()
        timeoutTask.cancel()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        return ShellResult(
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
    }

    // MARK: - File Operations (host-local, sandbox-confined)

    func readFile(path: String) async throws -> FileReadResult {
        let resolved = try session.validatePath(path)
        let data = try Data(contentsOf: resolved)

        let ext = resolved.pathExtension.lowercased()
        let imageExtensions = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif"]
        if imageExtensions.contains(ext) {
            let base64 = data.base64EncodedString()
            let mimeType: String
            switch ext {
            case "png": mimeType = "image/png"
            case "jpg", "jpeg": mimeType = "image/jpeg"
            case "gif": mimeType = "image/gif"
            case "webp": mimeType = "image/webp"
            default: mimeType = "application/octet-stream"
            }
            return .image(base64: base64, mimeType: mimeType, width: nil, height: nil)
        }

        let content = String(data: data, encoding: .utf8) ?? data.base64EncodedString()
        return .text(content: content, fileType: ext.isEmpty ? "text" : ext)
    }

    func writeFile(path: String, contents: String) async throws {
        let resolved = try session.validatePath(path)
        let fm = FileManager.default
        let parentDir = resolved.deletingLastPathComponent()
        if !fm.fileExists(atPath: parentDir.path) {
            try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }
        try contents.write(to: resolved, atomically: true, encoding: .utf8)
    }

    func listDirectory(path: String) async throws -> Any {
        let resolved = try session.validatePath(path)
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(
            at: resolved,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        return entries.sorted {
            $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
        }.map { entry -> [String: Any] in
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            return [
                "name": entry.lastPathComponent,
                "isDirectory": values?.isDirectory ?? false,
                "size": values?.fileSize ?? 0,
                "modifiedAt": Int((values?.contentModificationDate ?? Date()).timeIntervalSince1970)
            ]
        }
    }

    func moveFile(source: String, destination: String) async throws {
        let resolvedSource = try session.validatePath(source)
        let resolvedDest = try session.validatePath(destination)
        let fm = FileManager.default
        let parentDir = resolvedDest.deletingLastPathComponent()
        if !fm.fileExists(atPath: parentDir.path) {
            try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }
        try fm.moveItem(at: resolvedSource, to: resolvedDest)
    }

    // MARK: - Disconnect

    func disconnect() {
        AppFocusManager.shared.releaseAll(connectionId: connectionId)
        lockedAppKeys.removeAll()
    }

    // MARK: - Private helpers

    private func synthesizeDrag(from start: CGPoint, to end: CGPoint, pid: pid_t) {
        guard let downEvent = CGEvent(
            mouseEventSource: nil, mouseType: .leftMouseDown,
            mouseCursorPosition: start, mouseButton: .left
        ) else { return }
        downEvent.postToPid(pid)

        let steps = 10
        for i in 1...steps {
            let frac = CGFloat(i) / CGFloat(steps)
            let pt = CGPoint(
                x: start.x + (end.x - start.x) * frac,
                y: start.y + (end.y - start.y) * frac
            )
            guard let dragEvent = CGEvent(
                mouseEventSource: nil, mouseType: .leftMouseDragged,
                mouseCursorPosition: pt, mouseButton: .left
            ) else { continue }
            dragEvent.postToPid(pid)
            usleep(10_000)
        }

        guard let upEvent = CGEvent(
            mouseEventSource: nil, mouseType: .leftMouseUp,
            mouseCursorPosition: end, mouseButton: .left
        ) else { return }
        upEvent.postToPid(pid)
    }

    private func synthesizeScroll(at point: CGPoint, deltaX: Double, deltaY: Double, pid: pid_t) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(deltaY),
            wheel2: Int32(deltaX),
            wheel3: 0
        ) else { return }
        event.location = point
        event.postToPid(pid)
    }
}
