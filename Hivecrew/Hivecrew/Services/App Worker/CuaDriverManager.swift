//
//  CuaDriverManager.swift
//  Hivecrew
//
//  Manages the bundled cua-driver binary lifecycle: locate, launch as
//  long-lived MCP stdio subprocess, check/request macOS permissions,
//  and expose status to the Settings UI.
//

import Foundation
import AppKit
import Combine
import HivecrewCore
import HivecrewMCP

// MARK: - Status enums

enum CuaBinaryStatus: String, Sendable {
    case unknown
    case found
    case missing
}

enum CuaBackendStatus: String, Sendable {
    case stopped
    case starting
    case running
    case failed
}

enum SystemSettingsPane: String {
    case accessibility = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    case screenRecording = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
}

// MARK: - CuaDriverManager

@MainActor
final class CuaDriverManager: ObservableObject {
    static let shared = CuaDriverManager()

    static let expectedVersion = "0.0.5"

    @Published private(set) var binaryStatus: CuaBinaryStatus = .unknown
    @Published private(set) var binaryPath: String?
    @Published private(set) var binaryVersion: String?
    @Published private(set) var accessibilityGranted: Bool = false
    @Published private(set) var screenRecordingGranted: Bool = false
    @Published private(set) var backendStatus: CuaBackendStatus = .stopped
    @Published private(set) var lastError: String?
    @Published private(set) var selfTestResult: String?

    private var mcpClient: MCPClient?
    private var clientRefCount: Int = 0

    private init() {}

    // MARK: - Configure (called at app startup)

    func configure() {
        // Lightweight probe — doesn't launch the backend.
        Task { await refreshStatus() }
    }

    // MARK: - Status

    func refreshStatus() async {
        probeBinary()
        probePermissions()
        if let client = mcpClient {
            let initialized = await client.isInitialized
            backendStatus = initialized ? .running : .failed
        }
    }

    // MARK: - Binary resolution

    private func probeBinary() {
        if let url = locateBinary() {
            binaryStatus = .found
            binaryPath = url.path
        } else {
            binaryStatus = .missing
            binaryPath = nil
            binaryVersion = nil
        }
    }

    func locateBinary() -> URL? {
        if let url = Bundle.main.url(forAuxiliaryExecutable: "cua-driver") {
            return url
        }
        if let url = Bundle.main.url(forResource: "cua-driver", withExtension: nil, subdirectory: "cua-driver") {
            return url
        }
        if let url = Bundle.main.url(forResource: "cua-driver", withExtension: nil) {
            return url
        }
        // Check for CuaDriver.app inside cua-driver subdirectory
        if let appURL = Bundle.main.url(forResource: "CuaDriver", withExtension: "app", subdirectory: "cua-driver") {
            let binaryURL = appURL.appendingPathComponent("Contents/MacOS/cua-driver")
            if FileManager.default.isExecutableFile(atPath: binaryURL.path) {
                return binaryURL
            }
        }
        return nil
    }

    private func probeVersion() async {
        guard let binary = locateBinary() else {
            binaryVersion = nil
            return
        }
        do {
            let process = Process()
            process.executableURL = binary
            process.arguments = ["--version"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            binaryVersion = output
        } catch {
            binaryVersion = nil
        }
    }

    // MARK: - Permissions

    func probePermissions() {
        accessibilityGranted = AXIsProcessTrusted()
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
    }

    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        // Re-probe after a short delay to pick up user action
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            probePermissions()
        }
    }

    func requestScreenRecordingPermission() {
        CGRequestScreenCaptureAccess()
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            probePermissions()
        }
    }

    func openSystemSettings(for pane: SystemSettingsPane) {
        if let url = URL(string: pane.rawValue) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Backend lifecycle

    func ensureBackend() async throws -> MCPClient {
        if let existing = mcpClient, await existing.isInitialized {
            clientRefCount += 1
            return existing
        }

        guard let binary = locateBinary() else {
            binaryStatus = .missing
            throw CuaDriverError.binaryMissing
        }

        probePermissions()
        guard accessibilityGranted else { throw CuaDriverError.accessibilityMissing }
        guard screenRecordingGranted else { throw CuaDriverError.screenRecordingMissing }

        backendStatus = .starting
        lastError = nil

        do {
            let client = MCPClient(
                command: binary.path,
                arguments: ["mcp"]
            )

            try await client.start()

            mcpClient = client
            clientRefCount = 1
            backendStatus = .running

            await probeVersion()

            return client
        } catch {
            backendStatus = .failed
            lastError = error.localizedDescription
            throw CuaDriverError.launchFailed(error.localizedDescription)
        }
    }

    func stopBackend() async {
        guard let client = mcpClient else { return }
        try? await client.stop()
        mcpClient = nil
        clientRefCount = 0
        backendStatus = .stopped
    }

    func releaseClient() {
        clientRefCount = max(0, clientRefCount - 1)
    }

    // MARK: - Self-test

    func runSelfTest() async throws {
        selfTestResult = nil
        let client = try await ensureBackend()
        defer { releaseClient() }

        let result = try await client.callTool(name: "list_apps", arguments: [:])
        if result.isError == true {
            let errorText = result.textContent
            selfTestResult = "Failed: \(errorText)"
            throw CuaDriverError.selfTestFailed(errorText)
        }
        selfTestResult = "Success: list_apps returned \(result.content.count) content block(s)"
    }

    // MARK: - Setup requirement

    func currentSetupRequirement() -> RuntimeSetupRequirement? {
        probeBinary()
        probePermissions()
        if binaryStatus == .missing { return .cuaDriverMissing }
        if !accessibilityGranted || !screenRecordingGranted { return .appPermissionsMissing }
        return nil
    }
}

// MARK: - Errors

enum CuaDriverError: Error, LocalizedError {
    case binaryMissing
    case accessibilityMissing
    case screenRecordingMissing
    case launchFailed(String)
    case selfTestFailed(String)
    case toolCallFailed(String)
    case noWindowSelected
    case noAppSelected
    case permissionRevoked(String)

    var errorDescription: String? {
        switch self {
        case .binaryMissing:
            return "cua-driver binary was not found in the app bundle."
        case .accessibilityMissing:
            return "Accessibility permission is required for App Worker."
        case .screenRecordingMissing:
            return "Screen Recording permission is required for App Worker."
        case .launchFailed(let detail):
            return "Failed to launch cua-driver: \(detail)"
        case .selfTestFailed(let detail):
            return "cua-driver self-test failed: \(detail)"
        case .toolCallFailed(let detail):
            return "cua-driver tool call failed: \(detail)"
        case .noWindowSelected:
            return "No window is currently selected. Call app_list_windows and app_select_window first."
        case .noAppSelected:
            return "No app is currently targeted. Call app_list_apps and open_app first."
        case .permissionRevoked(let detail):
            return "Permission was revoked during execution: \(detail)"
        }
    }
}
