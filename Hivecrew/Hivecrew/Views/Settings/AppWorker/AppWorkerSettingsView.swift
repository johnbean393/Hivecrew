//
//  AppWorkerSettingsView.swift
//  Hivecrew
//
//  Settings panel for the App Worker runtime: cua-driver status,
//  macOS permission management, backend lifecycle, and capacity.
//

import SwiftUI

struct AppWorkerSettingsView: View {
    @StateObject private var manager = CuaDriverManager.shared
    @StateObject private var focusManager = AppFocusManager.shared

    @State private var isTesting = false
    @State private var isStartingBackend = false

    var body: some View {
        Form {
            driverSection
            permissionsSection
            backendSection
            activeLocksSection
            testSection
        }
        .formStyle(.grouped)
        .onAppear {
            Task { await manager.refreshStatus() }
        }
    }

    // MARK: - Driver

    private var driverSection: some View {
        Section {
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(manager.binaryStatus == .found ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(manager.binaryStatus == .found ? "Found" : "Missing")
                }
            }
            if let path = manager.binaryPath {
                LabeledContent("Path") {
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if let version = manager.binaryVersion {
                LabeledContent("Version", value: version)
            }
        } header: {
            Text("cua-driver Binary")
        }
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        Section {
            HStack {
                LabeledContent("Accessibility") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(manager.accessibilityGranted ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(manager.accessibilityGranted ? "Granted" : "Not Granted")
                    }
                }
                Spacer()
                if !manager.accessibilityGranted {
                    Button("Grant") {
                        manager.requestAccessibilityPermission()
                    }
                    .buttonStyle(.bordered)
                }
            }
            HStack {
                LabeledContent("Screen Recording") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(manager.screenRecordingGranted ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(manager.screenRecordingGranted ? "Granted" : "Not Granted")
                    }
                }
                Spacer()
                if !manager.screenRecordingGranted {
                    Button("Grant") {
                        manager.requestScreenRecordingPermission()
                    }
                    .buttonStyle(.bordered)
                }
            }
            HStack {
                Spacer()
                Button("Open System Settings") {
                    manager.openSystemSettings(for: .accessibility)
                }
                .buttonStyle(.link)
            }
        } header: {
            Text("macOS Permissions")
        } footer: {
            Text("App Worker requires Accessibility and Screen Recording permissions to control apps in the background.")
        }
    }

    // MARK: - Backend

    private var backendSection: some View {
        Section {
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(backendStatusColor)
                        .frame(width: 8, height: 8)
                    Text(backendStatusLabel)
                }
            }
            if let error = manager.lastError {
                LabeledContent("Last Error") {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }
            }
            HStack {
                Spacer()
                if manager.backendStatus == .stopped || manager.backendStatus == .failed {
                    Button("Start") {
                        isStartingBackend = true
                        Task {
                            _ = try? await manager.ensureBackend()
                            isStartingBackend = false
                        }
                    }
                    .disabled(isStartingBackend || manager.binaryStatus == .missing)
                    .buttonStyle(.bordered)
                }
                if manager.backendStatus == .running {
                    Button("Stop") {
                        Task { await manager.stopBackend() }
                    }
                    .buttonStyle(.bordered)
                }
            }
        } header: {
            Text("Backend")
        }
    }

    // MARK: - Active Locks

    private var activeLocksSection: some View {
        Section {
            let locks = focusManager.lockSummaries
            if locks.isEmpty {
                Text("No apps currently in use")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(locks, id: \.appKey) { lock in
                    HStack {
                        Image(systemName: "app.fill")
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(lock.appKey)
                                .font(.body)
                            if lock.waiters > 0 {
                                Text("\(lock.waiters) task(s) waiting")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                        Text("In Use")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("App Focus")
        } footer: {
            Text("Multiple tasks can run concurrently on different apps. Tasks targeting the same app are queued automatically.")
        }
    }

    // MARK: - Test

    private var testSection: some View {
        Section {
            HStack {
                Button("Run Self-Test") {
                    isTesting = true
                    Task {
                        try? await manager.runSelfTest()
                        isTesting = false
                    }
                }
                .disabled(isTesting || manager.binaryStatus == .missing)
                .buttonStyle(.bordered)

                if isTesting {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()

                if let result = manager.selfTestResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(result.hasPrefix("Success") ? .green : .red)
                }
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Calls list_apps on cua-driver to verify the backend is functional.")
        }
    }

    // MARK: - Helpers

    private var backendStatusColor: Color {
        switch manager.backendStatus {
        case .stopped: return .secondary
        case .starting: return .orange
        case .running: return .green
        case .failed: return .red
        }
    }

    private var backendStatusLabel: String {
        switch manager.backendStatus {
        case .stopped: return "Stopped"
        case .starting: return "Starting..."
        case .running: return "Running"
        case .failed: return "Failed"
        }
    }
}
