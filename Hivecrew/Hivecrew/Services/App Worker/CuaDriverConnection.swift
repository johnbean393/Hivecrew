//
//  CuaDriverConnection.swift
//  Hivecrew
//
//  AgentToolConnection conformance for the App Worker runtime.
//  Uses CuaDriverCore linked in-process for host macOS GUI control,
//  and provides local shell/file operations on the host filesystem.
//

import Foundation
import AppKit
import CoreGraphics
import HivecrewCore
import CuaDriverCore
import CuaDriverServer
import MCP

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

enum AppWorkerFocusRestoration {
    static func restorationPid(
        priorWorkspacePid: pid_t?,
        priorVisualPid: pid_t?,
        targetPid: pid_t?
    ) -> pid_t? {
        if let priorVisualPid, priorVisualPid != targetPid {
            return priorVisualPid
        }
        if let priorWorkspacePid, priorWorkspacePid != targetPid {
            return priorWorkspacePid
        }
        return nil
    }

    static func shouldRestore(
        priorWorkspacePid: pid_t?,
        priorVisualPid: pid_t?,
        currentWorkspacePid: pid_t?,
        currentVisualPid: pid_t?,
        targetPid: pid_t?,
        targetIsActive: Bool
    ) -> Bool {
        guard let targetPid else { return false }
        guard targetIsActive else { return false }

        guard let restorationPid = restorationPid(
            priorWorkspacePid: priorWorkspacePid,
            priorVisualPid: priorVisualPid,
            targetPid: targetPid
        ) else {
            return false
        }

        if let currentVisualPid,
           currentVisualPid != restorationPid,
           currentVisualPid != targetPid {
            return false
        }

        return currentWorkspacePid == targetPid
            || currentWorkspacePid == restorationPid
            || currentVisualPid == restorationPid
    }

    static func shouldNormalizeBeforeBackgroundAction(
        targetPid: pid_t?,
        visualPid: pid_t?,
        targetIsActive: Bool
    ) -> Bool {
        guard let targetPid, let visualPid else { return false }
        guard targetPid != visualPid else { return false }
        return targetIsActive
    }
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
    private let cuaTools = ToolRegistry.default

    var currentApp: AppContext?
    var currentWindow: WindowContext?
    var elementCache: [Int: AXElementSummary] = [:]
    var cachedLaunchWindows: (pid: Int, windows: [WindowSummary])?
    var lastInteractedElementIndex: Int?
    var lastInteractedElement: AXUIElement?
    var chromiumBundleDetectionCache: [Int: Bool] = [:]

    var lockedAppKeys: Set<String> = []

    init(
        session: AppWorkerSession,
        engine: AppStateEngine,
        capture: WindowCapture,
        focusGuard: FocusGuard,
        todoManager: TodoManager? = nil
    ) {
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
        guard bundleId != nil || appName != nil else {
            throw CuaDriverError.toolCallFailed("Provide either bundle_id or name.")
        }

        let appKey = AppFocusManager.normalizedKey(bundleId: bundleId, appName: appName)
        await AppFocusManager.shared.acquire(appKey: appKey, connectionId: connectionId)
        lockedAppKeys.insert(appKey)

        let info = try await launchAppInBackground(bundleId: bundleId, appName: appName)
        await selectLaunchedApp(info, fallbackName: appName, fallbackBundleId: bundleId)
    }

    func openURLInApp(_ urlString: String, bundleId: String?, appName: String?) async throws {
        let url = try resolveAppOpenURL(urlString)
        var resolvedBundleId = bundleId
        var resolvedAppName = appName

        if resolvedBundleId == nil && resolvedAppName == nil,
           let appURL = NSWorkspace.shared.urlForApplication(toOpen: url) {
            resolvedBundleId = Bundle(url: appURL)?.bundleIdentifier
            resolvedAppName = appURL.deletingPathExtension().lastPathComponent
        }

        let appKey = AppFocusManager.normalizedKey(
            bundleId: resolvedBundleId,
            appName: resolvedAppName
        )
        await AppFocusManager.shared.acquire(appKey: appKey, connectionId: connectionId)
        lockedAppKeys.insert(appKey)

        let info = try await launchAppInBackground(
            bundleId: resolvedBundleId,
            appName: resolvedAppName,
            urls: [url]
        )
        await selectLaunchedApp(
            info,
            fallbackName: resolvedAppName,
            fallbackBundleId: resolvedBundleId
        )
    }

    private func launchAppInBackground(
        bundleId: String?,
        appName: String?,
        urls: [URL] = []
    ) async throws -> AppInfo {
        var arguments: [String: Value] = [:]
        if let bundleId, !bundleId.isEmpty {
            arguments["bundle_id"] = .string(bundleId)
        }
        if let appName, !appName.isEmpty {
            arguments["name"] = .string(appName)
        }
        if !urls.isEmpty {
            arguments["urls"] = .array(urls.map { .string($0.absoluteString) })
        }

        let result = try await callCuaTool("launch_app", arguments)
        if let info = parseLaunchInfo(result.structuredContent) {
            return info
        }

        if let app = runningApplication(bundleId: bundleId, appName: appName) {
            return AppInfo(
                pid: app.processIdentifier,
                bundleId: app.bundleIdentifier ?? bundleId,
                name: app.localizedName ?? appName ?? bundleId ?? "app",
                running: !app.isTerminated,
                active: app.isActive
            )
        }

        throw CuaDriverError.toolCallFailed(
            "CuaDriver launch_app succeeded but did not return app identity."
        )
    }

    private func selectLaunchedApp(
        _ info: AppInfo,
        fallbackName: String?,
        fallbackBundleId: String?
    ) async {
        let pid = Int(info.pid)
        let resolvedName = info.name.isEmpty ? (fallbackName ?? "app") : info.name
        let resolvedBundleId = info.bundleId ?? fallbackBundleId

        currentApp = AppContext(pid: pid, appName: resolvedName, bundleId: resolvedBundleId)
        elementCache = [:]
        lastInteractedElementIndex = nil
        lastInteractedElement = nil

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

    private func runningApplication(bundleId: String?, appName: String?) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { app in
            if let bid = bundleId, !bid.isEmpty, app.bundleIdentifier == bid { return true }
            if let name = appName, !name.isEmpty,
               app.localizedName?.localizedCaseInsensitiveCompare(name) == .orderedSame { return true }
            return false
        }
    }

    private func resolveAppOpenURL(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CuaDriverError.toolCallFailed("url must not be empty.")
        }
        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }
        if trimmed.hasPrefix("~/") {
            return URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath)
        }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed)
        }
        guard let url = URL(string: "https://\(trimmed)") else {
            throw CuaDriverError.toolCallFailed("Invalid URL: \(raw)")
        }
        return url
    }

    func openFile(path: String, withApp: String?) async throws {
        let url = URL(fileURLWithPath: path)
        var bundleId: String?
        var appName: String?
        if let app = withApp, !app.isEmpty {
            let appURL = URL(fileURLWithPath: (app as NSString).expandingTildeInPath)
            if FileManager.default.fileExists(atPath: appURL.path) {
                bundleId = Bundle(url: appURL)?.bundleIdentifier
                appName = appURL.deletingPathExtension().lastPathComponent
            } else {
                appName = app
            }
        } else if let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url) {
            bundleId = Bundle(url: defaultApp)?.bundleIdentifier
            appName = defaultApp.deletingPathExtension().lastPathComponent
        } else {
            throw CuaDriverError.toolCallFailed(
                "No application found to open file: \(path). Specify an app with the withApp parameter."
            )
        }

        let info = try await launchAppInBackground(bundleId: bundleId, appName: appName, urls: [url])
        await selectLaunchedApp(info, fallbackName: appName, fallbackBundleId: bundleId)
    }

    func openUrl(_ urlString: String) async throws {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if trimmed.hasPrefix("x-apple.systempreferences:") {
            try await openURLInApp(trimmed, bundleId: "com.apple.systempreferences", appName: "System Settings")
            return
        }
        try await openURLInApp(trimmed, bundleId: nil, appName: nil)
    }

    // MARK: - Mouse (pixel-level via CuaDriverCore)

    func mouseMove(x: Double, y: Double) async throws {
        throw CuaDriverError.toolCallFailed(
            "mouse_move is not available in App Worker. Use CuaDriver element-indexed app tools instead."
        )
    }

    func mouseClick(x: Double, y: Double, button: String, clickType: String) async throws {
        guard let window = currentWindow else { throw CuaDriverError.noWindowSelected }
        let count: Int
        switch clickType {
        case "double": count = 2
        case "triple": count = 3
        default: count = 1
        }

        switch button {
        case "left", "":
            _ = try await callCuaTool("click", [
                "pid": .int(window.pid),
                "window_id": .int(window.windowId),
                "x": .double(x),
                "y": .double(y),
                "count": .int(count),
            ])
        case "right":
            _ = try await callCuaTool("right_click", [
                "pid": .int(window.pid),
                "window_id": .int(window.windowId),
                "x": .double(x),
                "y": .double(y),
            ])
        default:
            throw CuaDriverError.toolCallFailed(
                "Unsupported App Worker mouse button '\(button)'. Use left or right."
            )
        }
    }

    func mouseDrag(fromX: Double, fromY: Double, toX: Double, toY: Double) async throws {
        guard let window = currentWindow else { throw CuaDriverError.noWindowSelected }
        _ = try await callCuaTool("drag", [
            "pid": .int(window.pid),
            "window_id": .int(window.windowId),
            "from_x": .double(fromX),
            "from_y": .double(fromY),
            "to_x": .double(toX),
            "to_y": .double(toY),
        ])
    }

    // MARK: - Keyboard (via CuaDriverCore)

    func keyboardType(text: String) async throws {
        guard let window = currentWindow else { throw CuaDriverError.noWindowSelected }
        var arguments: [String: Value] = [
            "pid": .int(window.pid),
            "text": .string(text),
        ]
        if let index = lastInteractedElementIndex {
            arguments["window_id"] = .int(window.windowId)
            arguments["element_index"] = .int(index)
        }
        arguments["delay_ms"] = .int(isChromiumBackedCurrentTarget() ? 30 : 10)

        _ = try await callCuaTool("type_text", arguments)
    }

    /// Key combinations that macOS intercepts at the system level before
    /// PID-targeted CGEvent delivery, causing app switching or window hiding.
    private static let focusStealingHotkeys: Set<[String]> = [
        ["command", "tab"],
        ["command", "shift", "tab"],
        ["command", "space"],
        ["command", "option", "space"],
        ["command", "l"],
        ["command", "shift", "g"],
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
            let normalized = Set((filtered + [key]).map { Self.normalizedShortcutName($0) })
            for forbidden in Self.focusStealingHotkeys {
                if normalized == Set(forbidden) {
                    throw CuaDriverError.toolCallFailed(
                        "Key combination \(filtered.joined(separator: "+"))+\(key) "
                        + "is intercepted by macOS and would switch apps or hide windows. "
                        + "Use app_click_element or another approach instead."
                    )
                }
            }
        }

        var arguments: [String: Value] = [
            "pid": .int(Int(pid)),
            "key": .string(key),
        ]
        if !filtered.isEmpty {
            arguments["modifiers"] = .array(filtered.map { .string(Self.cuaModifierName($0)) })
            arguments["window_id"] = .int(window.windowId)
        }
        if let index = lastInteractedElementIndex {
            arguments["window_id"] = .int(window.windowId)
            arguments["element_index"] = .int(index)
        }
        _ = try await callCuaTool("press_key", arguments)
    }

    private static func cuaModifierName(_ modifier: String) -> String {
        switch modifier.lowercased() {
        case "command", "cmd": return "cmd"
        case "control", "ctrl": return "ctrl"
        case "function", "fn": return "fn"
        default: return modifier.lowercased()
        }
    }

    private static func normalizedShortcutName(_ key: String) -> String {
        switch key.lowercased() {
        case "cmd": return "command"
        case "ctrl": return "control"
        case "fn": return "function"
        default: return key.lowercased()
        }
    }

    func scroll(x: Double, y: Double, deltaX: Double, deltaY: Double) async throws {
        guard let window = currentWindow else { throw CuaDriverError.noWindowSelected }
        guard let (direction, amount, by) = cuaScrollRequest(deltaX: deltaX, deltaY: deltaY) else {
            return
        }
        var arguments: [String: Value] = [
            "pid": .int(window.pid),
            "direction": .string(direction),
            "amount": .int(amount),
            "by": .string(by),
        ]
        if let index = lastInteractedElementIndex {
            arguments["window_id"] = .int(window.windowId)
            arguments["element_index"] = .int(index)
        }
        _ = try await callCuaTool("scroll", arguments)
    }

    // MARK: - Shell (host-local, rooted at session root)

    func runShell(command: String, timeout: Double?) async throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", command]
        process.currentDirectoryURL = session.paths.root

        var env = ProcessInfo.processInfo.environment
        env["HIVECREW_SESSION_ROOT"] = session.paths.root.path
        env["HIVECREW_INBOX"] = session.paths.inbox.path
        env["HIVECREW_WORKSPACE"] = session.paths.workspace.path
        env["HIVECREW_OUTBOX"] = session.paths.outbox.path
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

    // MARK: - File Operations (host-local)

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

    func callCuaTool(
        _ name: String,
        _ arguments: [String: Value],
        allowToolError: Bool = false
    ) async throws -> CallTool.Result {
        let targetPid = targetPid(from: arguments)
        let focusSnapshot = captureFocusSnapshot()
        let shouldCheckSettledFocus = shouldCheckSettledFocus(for: name, arguments: arguments)

        do {
            if shouldCheckSettledFocus {
                await normalizeFocusBeforeBackgroundAction(focusSnapshot, targetPid: targetPid)
            }
            let result = try await cuaTools.call(name, arguments: arguments)
            await restoreFrontmostAppIfNeeded(
                focusSnapshot,
                targetPid: targetPid,
                checkSettledFocus: shouldCheckSettledFocus
            )

            if result.isError == true && !allowToolError {
                throw CuaDriverError.toolCallFailed(firstTextContent(result) ?? "\(name) failed")
            }
            return result
        } catch {
            await restoreFrontmostAppIfNeeded(
                focusSnapshot,
                targetPid: targetPid,
                checkSettledFocus: shouldCheckSettledFocus
            )
            throw error
        }
    }

    private func firstTextContent(_ result: CallTool.Result) -> String? {
        for item in result.content {
            if case let .text(text, _, _) = item {
                return text
            }
        }
        return nil
    }

    private func targetPid(from arguments: [String: Value]) -> pid_t? {
        guard let rawPid = arguments["pid"]?.intValue else { return nil }
        return pid_t(exactly: rawPid)
    }

    private struct FocusSnapshot {
        let workspaceFrontmost: NSRunningApplication?
        let visualFrontmostWindow: WindowInfo?

        var visualFrontmost: NSRunningApplication? {
            visualFrontmostWindow
                .flatMap { NSRunningApplication(processIdentifier: $0.pid) }
        }

        func restorationApp(targetPid: pid_t?) -> NSRunningApplication? {
            guard let restorationPid = AppWorkerFocusRestoration.restorationPid(
                priorWorkspacePid: workspaceFrontmost?.processIdentifier,
                priorVisualPid: visualFrontmostWindow?.pid,
                targetPid: targetPid
            ) else {
                return nil
            }
            if visualFrontmostWindow?.pid == restorationPid {
                return visualFrontmost
            }
            if workspaceFrontmost?.processIdentifier == restorationPid {
                return workspaceFrontmost
            }
            return NSRunningApplication(processIdentifier: restorationPid)
        }

        func restorationWindow(targetPid: pid_t?) -> WindowInfo? {
            guard let visualFrontmostWindow,
                  visualFrontmostWindow.pid != targetPid else {
                return nil
            }
            return visualFrontmostWindow
        }
    }

    private func captureFocusSnapshot() -> FocusSnapshot {
        FocusSnapshot(
            workspaceFrontmost: NSWorkspace.shared.frontmostApplication,
            visualFrontmostWindow: visuallyFrontmostWindow()
        )
    }

    private func visuallyFrontmostApplication() -> NSRunningApplication? {
        visuallyFrontmostWindow()
            .flatMap { NSRunningApplication(processIdentifier: $0.pid) }
    }

    private func visuallyFrontmostWindow() -> WindowInfo? {
        WindowEnumerator.visibleWindows()
            .filter { $0.layer == 0 && $0.bounds.width > 1 && $0.bounds.height > 1 }
            .max(by: { $0.zIndex < $1.zIndex })
    }

    private func shouldCheckSettledFocus(for name: String, arguments: [String: Value]) -> Bool {
        switch name {
        case "click", "right_click", "double_click":
            return arguments["x"] != nil && arguments["y"] != nil
        case "drag":
            return true
        default:
            return false
        }
    }

    private func restoreFrontmostAppIfNeeded(
        _ snapshot: FocusSnapshot,
        targetPid: pid_t?,
        checkSettledFocus: Bool
    ) async {
        restoreFrontmostAppIfNeeded(snapshot, targetPid: targetPid)

        guard checkSettledFocus else { return }

        try? await Task.sleep(nanoseconds: 150_000_000)
        restoreFrontmostAppIfNeeded(snapshot, targetPid: targetPid)

        try? await Task.sleep(nanoseconds: 350_000_000)
        restoreFrontmostAppIfNeeded(snapshot, targetPid: targetPid)
    }

    private func normalizeFocusBeforeBackgroundAction(
        _ snapshot: FocusSnapshot,
        targetPid: pid_t?
    ) async {
        let targetIsActive = targetPid
            .flatMap { NSRunningApplication(processIdentifier: $0)?.isActive } ?? false

        guard AppWorkerFocusRestoration.shouldNormalizeBeforeBackgroundAction(
            targetPid: targetPid,
            visualPid: snapshot.visualFrontmostWindow?.pid,
            targetIsActive: targetIsActive
        ) else {
            return
        }

        guard let restorationWindow = snapshot.restorationWindow(targetPid: targetPid) else {
            return
        }

        _ = FocusWithoutRaise.activateWithoutRaise(
            targetPid: restorationWindow.pid,
            targetWid: CGWindowID(restorationWindow.id)
        )
        try? await Task.sleep(nanoseconds: 75_000_000)
    }

    private func restoreFrontmostAppIfNeeded(
        _ snapshot: FocusSnapshot,
        targetPid: pid_t?
    ) {
        let currentWorkspacePid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let currentVisualPid = visuallyFrontmostApplication()?.processIdentifier
        let targetIsActive = targetPid
            .flatMap { NSRunningApplication(processIdentifier: $0)?.isActive } ?? false

        guard AppWorkerFocusRestoration.shouldRestore(
            priorWorkspacePid: snapshot.workspaceFrontmost?.processIdentifier,
            priorVisualPid: snapshot.visualFrontmostWindow?.pid,
            currentWorkspacePid: currentWorkspacePid,
            currentVisualPid: currentVisualPid,
            targetPid: targetPid,
            targetIsActive: targetIsActive
        ) else {
            return
        }

        if let restorationWindow = snapshot.restorationWindow(targetPid: targetPid) {
            _ = FocusWithoutRaise.activateWithoutRaise(
                targetPid: restorationWindow.pid,
                targetWid: CGWindowID(restorationWindow.id)
            )
            return
        }

        _ = snapshot.restorationApp(targetPid: targetPid)?.activate(options: [.activateIgnoringOtherApps])
    }

    private func parseLaunchInfo(_ value: Value?) -> AppInfo? {
        guard let object = value?.objectValue,
              let pid = object["pid"]?.intValue,
              let checkedPid = Int32(exactly: pid) else {
            return nil
        }
        return AppInfo(
            pid: checkedPid,
            bundleId: object["bundle_id"]?.stringValue,
            name: object["name"]?.stringValue ?? "app",
            running: object["running"]?.boolValue ?? true,
            active: object["active"]?.boolValue ?? false
        )
    }

    private func cuaScrollRequest(deltaX: Double, deltaY: Double) -> (direction: String, amount: Int, by: String)? {
        let useVertical = abs(deltaY) >= abs(deltaX)
        let delta = useVertical ? deltaY : deltaX
        let magnitude = abs(delta)
        guard magnitude >= 0.5 else { return nil }

        let direction: String
        if useVertical {
            direction = delta < 0 ? "down" : "up"
        } else {
            direction = delta < 0 ? "right" : "left"
        }

        if magnitude >= 10 {
            return (
                direction: direction,
                amount: min(5, max(1, Int((magnitude / 10).rounded(.up)))),
                by: "page"
            )
        }
        return (
            direction: direction,
            amount: min(50, max(1, Int(magnitude.rounded()))),
            by: "line"
        )
    }

    func lookupLastInteractedElement(for window: WindowContext) async -> AXUIElement? {
        guard let index = lastInteractedElementIndex else { return nil }
        return try? await engine.lookup(
            pid: Int32(window.pid),
            windowId: UInt32(window.windowId),
            elementIndex: index
        )
    }

    func isChromiumBackedCurrentTarget() -> Bool {
        let pid = currentWindow?.pid ?? currentApp?.pid
        if let pid, appBundleLooksChromiumBacked(pid: pid) {
            return true
        }

        // Electron/Chromium-backed apps commonly expose the page as AXWebArea.
        if elementCache.values.contains(where: { $0.role == "AXWebArea" }) {
            return true
        }

        // Fallback for browser shells whose bundles may be outside normal
        // locations, unreadable, or represented by helper processes.
        let bundleId = currentApp?.bundleId?.lowercased() ?? ""
        let appName = currentApp?.appName.lowercased() ?? ""
        let chromiumBundlePrefixes = [
            "com.google.chrome",
            "org.chromium.chromium",
            "com.microsoft.edgemac",
            "com.brave.browser",
            "com.vivaldi.vivaldi",
            "com.operasoftware.opera",
            "company.thebrowser.browser",
        ]
        if chromiumBundlePrefixes.contains(where: { bundleId.hasPrefix($0) }) {
            return true
        }

        let chromiumNameFragments = [
            "chrome",
            "chromium",
            "microsoft edge",
            "brave",
            "vivaldi",
            "opera",
            "arc",
        ]
        if chromiumNameFragments.contains(where: { appName.contains($0) }) {
            return true
        }

        return false
    }

    private func appBundleLooksChromiumBacked(pid: Int) -> Bool {
        if let cached = chromiumBundleDetectionCache[pid] {
            return cached
        }

        guard let app = NSRunningApplication(processIdentifier: pid_t(pid)),
              let bundleURL = app.bundleURL else {
            chromiumBundleDetectionCache[pid] = false
            return false
        }

        let detected = bundleContainsChromiumMarkers(bundleURL)
        chromiumBundleDetectionCache[pid] = detected
        return detected
    }

    private func bundleContainsChromiumMarkers(_ bundleURL: URL) -> Bool {
        let fm = FileManager.default

        let markerNames = [
            "Electron Framework.framework",
            "Chromium Embedded Framework.framework",
            "Chromium Framework.framework",
            "Google Chrome Framework.framework",
            "Microsoft Edge Framework.framework",
            "Brave Browser Framework.framework",
            "Vivaldi Framework.framework",
            "Opera Framework.framework",
            "libcef.dylib",
            "libcef.so",
        ].map { $0.lowercased() }

        let markerSubstrings = [
            "electron framework",
            "chromium embedded framework",
            "chromium framework",
            "chrome framework",
            "libcef",
        ]

        let candidateRoots = [
            bundleURL.appendingPathComponent("Contents/Frameworks"),
            bundleURL.appendingPathComponent("Contents/Helpers"),
            bundleURL.appendingPathComponent("Contents/Versions"),
            bundleURL.appendingPathComponent("Contents/Resources"),
        ]

        for root in candidateRoots where fm.fileExists(atPath: root.path) {
            if directoryContainsChromiumMarker(root, markerNames: markerNames, markerSubstrings: markerSubstrings) {
                return true
            }
        }

        return false
    }

    private func directoryContainsChromiumMarker(
        _ root: URL,
        markerNames: [String],
        markerSubstrings: [String],
        maxDepth: Int = 4
    ) -> Bool {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return false
        }

        let rootDepth = root.pathComponents.count
        for case let url as URL in enumerator {
            let depth = url.pathComponents.count - rootDepth
            if depth > maxDepth {
                enumerator.skipDescendants()
                continue
            }

            let name = url.lastPathComponent.lowercased()
            if markerNames.contains(name) || markerSubstrings.contains(where: { name.contains($0) }) {
                return true
            }
        }

        return false
    }

}
