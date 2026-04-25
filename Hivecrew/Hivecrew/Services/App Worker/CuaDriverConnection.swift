//
//  CuaDriverConnection.swift
//  Hivecrew
//
//  AgentToolConnection conformance for the App Worker runtime.
//  Wraps a cua-driver MCP subprocess for host macOS GUI control
//  and provides local shell/file operations via the session sandbox.
//

import Foundation
import AppKit
import HivecrewCore
import HivecrewMCP

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
}

struct WindowStateSnapshot: Sendable {
    var elements: [AXElementSummary]
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
    let mcp: MCPClient
    let session: AppWorkerSession
    weak var todoManager: TodoManager?

    var currentApp: AppContext?
    var currentWindow: WindowContext?
    var elementCache: [Int: AXElementSummary] = [:]

    var lockedAppKeys: Set<String> = []

    init(mcp: MCPClient, session: AppWorkerSession, todoManager: TodoManager? = nil) {
        self.connectionId = UUID().uuidString
        self.mcp = mcp
        self.session = session
        self.todoManager = todoManager
    }

    // MARK: - Observation

    func screenshot() async throws -> ScreenshotResult? {
        guard let window = currentWindow else { return nil }

        let result = try await mcp.callTool(name: "get_window_state", arguments: [
            "pid": .int(window.pid),
            "window_id": .int(window.windowId),
            "capture_mode": .string("vision")
        ])
        guard result.isError != true else { return nil }

        for content in result.content {
            if content.type == "image", let data = content.data {
                return ScreenshotResult(
                    imageBase64: data,
                    width: 0,
                    height: 0
                )
            }
        }
        return nil
    }

    func observe() async throws -> RuntimeObservation {
        guard let window = currentWindow else {
            var obs = session.textObservation(todoManager: todoManager)
            obs.text += "\n\nNo app/window selected. Use app_list_apps to discover running apps, then open_app and app_list_windows to target a window."
            return obs
        }

        let state = try await getWindowState()
        elementCache = Dictionary(uniqueKeysWithValues: state.elements.map { ($0.index, $0) })

        var lines: [String] = []
        lines.append("Runtime: App Worker (host macOS GUI)")
        lines.append("Current app: \(currentApp?.appName ?? "unknown") (pid: \(window.pid))")
        lines.append("Current window: \(window.title) (id: \(window.windowId))")
        lines.append("")
        lines.append("Accessible elements:")
        for element in state.elements {
            var line = "[\(element.index)] \(element.role) \"\(element.label)\""
            if let value = element.value, !value.isEmpty {
                line += " value=\"\(value)\""
            }
            lines.append(line)
        }

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
        // Acquire per-app focus lock before interacting
        let appKey = AppFocusManager.normalizedKey(bundleId: bundleId, appName: appName)
        await AppFocusManager.shared.acquire(appKey: appKey, connectionId: connectionId)
        lockedAppKeys.insert(appKey)

        var args: [String: AnyCodableValue] = [:]
        if let bid = bundleId { args["bundle_id"] = .string(bid) }
        if let name = appName { args["app_name"] = .string(name) }

        let result = try await mcp.callTool(name: "launch_app", arguments: args)
        if result.isError == true {
            throw CuaDriverError.toolCallFailed(result.textContent)
        }

        if let text = result.content.first?.text,
           let pidRange = text.range(of: #"\"pid\"\s*:\s*(\d+)"#, options: .regularExpression),
           let pidStr = text[pidRange].split(separator: ":").last?.trimmingCharacters(in: .whitespacesAndNewlines),
           let pid = Int(pidStr) {
            currentApp = AppContext(pid: pid, appName: appName ?? bundleId ?? "app", bundleId: bundleId)
            currentWindow = nil
            elementCache = [:]
        }
    }

    func openFile(path: String, withApp: String?) async throws {
        let url = URL(fileURLWithPath: path)
        if let app = withApp {
            try await NSWorkspace.shared.open(
                [url],
                withApplicationAt: URL(fileURLWithPath: app),
                configuration: NSWorkspace.OpenConfiguration()
            )
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    func openUrl(_ url: String) async throws {
        guard let nsUrl = URL(string: url) else { return }
        NSWorkspace.shared.open(nsUrl)
    }

    // MARK: - Mouse/Keyboard/Scroll (pixel-level, existing protocol methods)

    func mouseMove(x: Double, y: Double) async throws {
        guard let window = currentWindow else { throw CuaDriverError.noWindowSelected }
        let result = try await mcp.callTool(name: "mouse_move", arguments: [
            "pid": .int(window.pid),
            "window_id": .int(window.windowId),
            "x": .double(x),
            "y": .double(y)
        ])
        if result.isError == true {
            throw CuaDriverError.toolCallFailed(result.textContent)
        }
    }

    func mouseClick(x: Double, y: Double, button: String, clickType: String) async throws {
        guard let window = currentWindow else { throw CuaDriverError.noWindowSelected }

        var args: [String: AnyCodableValue] = [
            "pid": .int(window.pid),
            "window_id": .int(window.windowId),
            "x": .double(x),
            "y": .double(y)
        ]
        if button != "left" { args["button"] = .string(button) }
        if clickType == "double" { args["click_type"] = .string("double") }

        let result = try await mcp.callTool(name: "click", arguments: args)
        if result.isError == true {
            throw CuaDriverError.toolCallFailed(result.textContent)
        }
    }

    func mouseDrag(fromX: Double, fromY: Double, toX: Double, toY: Double) async throws {
        guard let window = currentWindow else { throw CuaDriverError.noWindowSelected }
        let result = try await mcp.callTool(name: "drag", arguments: [
            "pid": .int(window.pid),
            "window_id": .int(window.windowId),
            "start_x": .double(fromX),
            "start_y": .double(fromY),
            "end_x": .double(toX),
            "end_y": .double(toY)
        ])
        if result.isError == true {
            throw CuaDriverError.toolCallFailed(result.textContent)
        }
    }

    func keyboardType(text: String) async throws {
        guard let window = currentWindow else { throw CuaDriverError.noWindowSelected }
        let result = try await mcp.callTool(name: "type_text", arguments: [
            "pid": .int(window.pid),
            "window_id": .int(window.windowId),
            "text": .string(text)
        ])
        if result.isError == true {
            throw CuaDriverError.toolCallFailed(result.textContent)
        }
    }

    func keyboardKey(key: String, modifiers: [String]) async throws {
        guard let window = currentWindow else { throw CuaDriverError.noWindowSelected }
        var args: [String: AnyCodableValue] = [
            "pid": .int(window.pid),
            "window_id": .int(window.windowId),
            "key": .string(key)
        ]
        if !modifiers.isEmpty {
            let toolName = modifiers.count == 1 && modifiers[0].isEmpty ? "press_key" : "hotkey"
            if toolName == "hotkey" {
                args["modifiers"] = .array(modifiers.map { .string($0) })
                let result = try await mcp.callTool(name: "hotkey", arguments: args)
                if result.isError == true {
                    throw CuaDriverError.toolCallFailed(result.textContent)
                }
                return
            }
        }
        let result = try await mcp.callTool(name: "press_key", arguments: args)
        if result.isError == true {
            throw CuaDriverError.toolCallFailed(result.textContent)
        }
    }

    func scroll(x: Double, y: Double, deltaX: Double, deltaY: Double) async throws {
        guard let window = currentWindow else { throw CuaDriverError.noWindowSelected }
        let result = try await mcp.callTool(name: "scroll", arguments: [
            "pid": .int(window.pid),
            "window_id": .int(window.windowId),
            "x": .double(x),
            "y": .double(y),
            "delta_x": .double(deltaX),
            "delta_y": .double(deltaY)
        ])
        if result.isError == true {
            throw CuaDriverError.toolCallFailed(result.textContent)
        }
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
        CuaDriverManager.shared.releaseClient()
    }
}
