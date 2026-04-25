//
//  AppWorkerSettingsView.swift
//  Hivecrew
//
//  Settings panel for the App Worker runtime: macOS permission
//  management and app focus status.
//

import SwiftUI
import CuaDriverCore

struct AppWorkerSettingsView: View {
    @StateObject private var manager = CuaDriverManager.shared
    @StateObject private var focusManager = AppFocusManager.shared

    var body: some View {
        Form {
            driverInfoSection
            permissionsSection
            activeLocksSection
        }
        .formStyle(.grouped)
        .onAppear {
            Task { await manager.refreshStatus() }
        }
    }

    // MARK: - Driver info

    private var driverInfoSection: some View {
        Section {
            LabeledContent("Engine") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    Text("CuaDriverCore (in-process)")
                }
            }
            LabeledContent("Version", value: CuaDriverCore.version)
        } header: {
            Text("CuaDriver")
        } footer: {
            Text("CuaDriverCore is linked directly into Hivecrew. All accessibility and screen capture operations run in-process.")
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
}
