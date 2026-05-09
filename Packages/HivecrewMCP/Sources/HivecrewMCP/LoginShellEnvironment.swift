//
//  LoginShellEnvironment.swift
//  HivecrewMCP
//
//  Loads a cached login-shell environment so MCP servers inherit the same
//  exported variables that are available in Terminal.app.
//

#if os(macOS)
import Darwin
import Foundation
import OSLog

private let shellEnvironmentLogger = Logger(
    subsystem: "com.pattonium.mcp",
    category: "LoginShellEnvironment"
)

struct LoginShellEnvironmentSnapshot {
    static let startMarker = "__HIVECREW_LOGIN_SHELL_ENV_START__"
    static let endMarker = "__HIVECREW_LOGIN_SHELL_ENV_END__"

    static let captureCommand = """
    printf '%s\\n' '\(startMarker)'
    /usr/bin/python3 - <<'PY'
    import json, os, sys
    json.dump(dict(os.environ), sys.stdout)
    print()
    PY
    printf '%s\\n' '\(endMarker)'
    """

    static func merge(
        base: [String: String],
        shell: [String: String],
        overrides: [String: String]?
    ) -> [String: String] {
        var merged = base
        merged.merge(shell) { _, new in new }

        if let overrides {
            merged.merge(overrides) { _, new in new }
        }

        return merged
    }

    static func parse(output: String) throws -> [String: String] {
        guard
            let startRange = output.range(of: startMarker),
            let endRange = output.range(of: endMarker, range: startRange.upperBound..<output.endIndex)
        else {
            throw LoginShellEnvironmentError.missingMarkers
        }

        let payload = output[startRange.upperBound..<endRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = payload.data(using: .utf8) else {
            throw LoginShellEnvironmentError.invalidEncoding
        }

        do {
            return try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            throw LoginShellEnvironmentError.invalidPayload(error.localizedDescription)
        }
    }
}

enum LoginShellEnvironmentError: LocalizedError {
    case missingMarkers
    case invalidEncoding
    case invalidPayload(String)
    case shellFailed(String)
    case shellTimedOut

    var errorDescription: String? {
        switch self {
        case .missingMarkers:
            return "Login shell output did not contain the expected environment markers."
        case .invalidEncoding:
            return "Login shell output could not be decoded as UTF-8."
        case .invalidPayload(let details):
            return "Login shell environment payload was invalid: \(details)"
        case .shellFailed(let details):
            return "Login shell environment capture failed: \(details)"
        case .shellTimedOut:
            return "Login shell environment capture timed out."
        }
    }
}

public actor LoginShellEnvironmentLoader {
    public static let shared = LoginShellEnvironmentLoader()

    private enum CachedResult {
        case success([String: String])
        case failure(String)
    }

    private var cachedResult: CachedResult?

    public func environment(merging overrides: [String: String]?) async -> [String: String] {
        let base = ProcessInfo.processInfo.environment
        let cachedResult = await cachedOrLoadResult()

        switch cachedResult {
        case .success(let shellEnvironment):
            return LoginShellEnvironmentSnapshot.merge(
                base: base,
                shell: shellEnvironment,
                overrides: overrides
            )

        case .failure(let reason):
            shellEnvironmentLogger.warning("Falling back to process environment: \(reason, privacy: .public)")

            var merged = base
            if let overrides {
                merged.merge(overrides) { _, new in new }
            }
            return merged
        }
    }

    private func cachedOrLoadResult() async -> CachedResult {
        if let cachedResult {
            return cachedResult
        }

        let loadedResult: CachedResult
        do {
            loadedResult = .success(try await loadEnvironment())
        } catch {
            loadedResult = .failure(error.localizedDescription)
        }

        cachedResult = loadedResult
        return loadedResult
    }

    private func loadEnvironment() async throws -> [String: String] {
        let shellPath = Self.loginShellPath()
        let output = try await runShell(
            executablePath: shellPath,
            arguments: ["-i", "-l", "-c", LoginShellEnvironmentSnapshot.captureCommand]
        )
        return try LoginShellEnvironmentSnapshot.parse(output: output)
    }

    private func runShell(executablePath: String, arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try Self.runShellSync(executablePath: executablePath, arguments: arguments))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func runShellSync(executablePath: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        let timeout = Date().addingTimeInterval(5)
        while process.isRunning && Date() < timeout {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            throw LoginShellEnvironmentError.shellTimedOut
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw LoginShellEnvironmentError.shellFailed(
                message.isEmpty ? "exit code \(process.terminationStatus)" : message
            )
        }

        return stdout
    }

    private static func loginShellPath() -> String {
        if let shellPointer = getpwuid(getuid())?.pointee.pw_shell,
           let shellPath = String(validatingCString: shellPointer),
           !shellPath.isEmpty {
            return shellPath
        }

        if let shellPath = ProcessInfo.processInfo.environment["SHELL"], !shellPath.isEmpty {
            return shellPath
        }

        return "/bin/zsh"
    }
}
#endif
