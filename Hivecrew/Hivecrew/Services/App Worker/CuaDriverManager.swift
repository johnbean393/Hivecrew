//
//  CuaDriverManager.swift
//  Hivecrew
//
//  Manages macOS permissions for the App Worker runtime and holds the
//  shared CuaDriverCore actor instances used by all CuaDriverConnections.
//  CuaDriverCore is linked in-process, so there is no external binary
//  or MCP subprocess to manage.
//

import Foundation
import AppKit
import Combine
import HivecrewCore
import CuaDriverCore
import CuaDriverServer

// MARK: - Status enums

enum CuaBackendStatus: String, Sendable {
    case stopped
    case running
}

enum SystemSettingsPane: String {
    case accessibility = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    case screenRecording = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
}

// MARK: - CuaDriverManager

@MainActor
final class CuaDriverManager: ObservableObject {
    static let shared = CuaDriverManager()

    @Published private(set) var accessibilityGranted: Bool = false
    @Published private(set) var screenRecordingGranted: Bool = false
    @Published private(set) var lastError: String?

    // Use CuaDriver's own shared registry so Hivecrew facade calls and
    // CuaDriverServer tool calls share the same AX cache and focus guard.
    private(set) lazy var systemFocusStealPreventer = AppStateRegistry.systemFocusStealPreventer
    private(set) lazy var engine: AppStateEngine = AppStateRegistry.engine
    private(set) lazy var capture: WindowCapture = WindowCapture()
    private(set) lazy var focusGuard: FocusGuard = AppStateRegistry.focusGuard

    private init() {}

    // MARK: - Configure (called at app startup)

    func configure() {
        Task { await refreshStatus() }
    }

    // MARK: - Status

    func refreshStatus() async {
        probePermissions()
    }

    // MARK: - Permissions

    func probePermissions() {
        accessibilityGranted = AXIsProcessTrusted()
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
    }

    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
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

    // MARK: - Setup requirement

    func currentSetupRequirement() -> RuntimeSetupRequirement? {
        probePermissions()
        if !accessibilityGranted || !screenRecordingGranted { return .appPermissionsMissing }
        return nil
    }
}

// MARK: - Errors

enum CuaDriverError: Error, LocalizedError {
    case accessibilityMissing
    case screenRecordingMissing
    case toolCallFailed(String)
    case noWindowSelected
    case noAppSelected
    case permissionRevoked(String)

    var errorDescription: String? {
        switch self {
        case .accessibilityMissing:
            return "Accessibility permission is required for App Worker."
        case .screenRecordingMissing:
            return "Screen Recording permission is required for App Worker."
        case .toolCallFailed(let detail):
            return "App Worker tool call failed: \(detail)"
        case .noWindowSelected:
            return "No window is currently selected. Call app_list_windows and app_select_window first."
        case .noAppSelected:
            return "No app is currently targeted. Call app_list_apps and open_app first."
        case .permissionRevoked(let detail):
            return "Permission was revoked during execution: \(detail)"
        }
    }
}
