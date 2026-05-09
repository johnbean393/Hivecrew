//
//  FastWorkerConnection.swift
//  Hivecrew
//
//  AgentToolConnection conformance for the headless Fast Worker runtime.
//  Supports shell and file read/write/list/move on the host filesystem.
//  All GUI/vision operations throw.
//

import Foundation
import HivecrewCore

enum FastWorkerConnectionError: Error, LocalizedError {
    case unsupportedForRuntime(String)
    case pathRejected(String)
    case shellFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedForRuntime(let tool):
            return "\(tool) is not available in the Fast Worker runtime."
        case .pathRejected(let path):
            return "Path '\(path)' is outside approved session roots."
        case .shellFailed(let detail):
            return "Shell command failed: \(detail)"
        }
    }
}

@MainActor
final class FastWorkerConnection: AgentToolConnection {
    let runtimeKind: AgentRuntimeKind = .fast
    let capabilities: RuntimeCapabilities = .fast

    let session: FastWorkerSession
    weak var todoManager: TodoManager?

    init(session: FastWorkerSession, todoManager: TodoManager? = nil) {
        self.session = session
        self.todoManager = todoManager
    }

    // MARK: - Observation

    func screenshot() async throws -> ScreenshotResult? { nil }

    func observe() async throws -> RuntimeObservation {
        session.textObservation(todoManager: todoManager)
    }

    // MARK: - GUI (all throw)

    func openApp(bundleId: String?, appName: String?) async throws {
        throw FastWorkerConnectionError.unsupportedForRuntime("open_app")
    }
    func openFile(path: String, withApp: String?) async throws {
        throw FastWorkerConnectionError.unsupportedForRuntime("open_file")
    }
    func openUrl(_ url: String) async throws {
        throw FastWorkerConnectionError.unsupportedForRuntime("open_url")
    }
    func mouseMove(x: Double, y: Double) async throws {
        throw FastWorkerConnectionError.unsupportedForRuntime("mouse_move")
    }
    func mouseClick(x: Double, y: Double, button: String, clickType: String) async throws {
        throw FastWorkerConnectionError.unsupportedForRuntime("mouse_click")
    }
    func mouseDrag(fromX: Double, fromY: Double, toX: Double, toY: Double) async throws {
        throw FastWorkerConnectionError.unsupportedForRuntime("mouse_drag")
    }
    func keyboardType(text: String) async throws {
        throw FastWorkerConnectionError.unsupportedForRuntime("keyboard_type")
    }
    func keyboardKey(key: String, modifiers: [String]) async throws {
        throw FastWorkerConnectionError.unsupportedForRuntime("keyboard_key")
    }
    func scroll(x: Double, y: Double, deltaX: Double, deltaY: Double) async throws {
        throw FastWorkerConnectionError.unsupportedForRuntime("scroll")
    }

    // MARK: - Shell

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
        let deadline = DispatchTime.now() + effectiveTimeout
        let processRef = process

        let timeoutTask = Task.detached {
            try await Task.sleep(nanoseconds: UInt64(effectiveTimeout * 1_000_000_000))
            if processRef.isRunning {
                processRef.terminate()
            }
        }

        process.waitUntilExit()
        timeoutTask.cancel()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        return ShellResult(
            stdout: stdout,
            stderr: stderr,
            exitCode: process.terminationStatus
        )
    }

    // MARK: - File Operations

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

    func disconnect() {}
}
