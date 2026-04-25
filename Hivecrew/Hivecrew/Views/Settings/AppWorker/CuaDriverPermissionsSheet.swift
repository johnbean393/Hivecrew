//
//  CuaDriverPermissionsSheet.swift
//  Hivecrew
//
//  First-time (and re-entry) flow: grant Accessibility + Screen Recording
//  so App Worker can run. Auto-dismisses when ready.
//

import AppKit
import Combine
import SwiftUI

struct CuaDriverPermissionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var manager = CuaDriverManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("App Worker needs your permission")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Grant both so Hivecrew can inspect and drive native apps on your behalf. This window closes on its own once each item shows as granted.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            permissionBlock(
                title: "Accessibility",
                description: "Needed to read the accessibility tree and send clicks and keystrokes.",
                ok: manager.accessibilityGranted,
                grant: { manager.requestAccessibilityPermission() },
                openSystemSettings: { manager.openSystemSettings(for: .accessibility) }
            )
            permissionBlock(
                title: "Screen Recording",
                description: "Needed for per-window screenshots so the agent can see the current UI.",
                ok: manager.screenRecordingGranted,
                grant: { manager.requestScreenRecordingPermission() },
                openSystemSettings: { manager.openSystemSettings(for: .screenRecording) }
            )

            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 480)
        .onAppear {
            Task { await manager.refreshStatus() }
        }
        .onReceive(Timer.publish(every: 0.75, on: .main, in: .common).autoconnect()) { _ in
            manager.probePermissions()
            if manager.currentSetupRequirement() == nil {
                dismiss()
            }
        }
    }

    private func permissionBlock(
        title: String,
        description: String,
        ok: Bool,
        grant: @escaping () -> Void,
        openSystemSettings: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                if ok {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .imageScale(.large)
                } else {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .imageScale(.large)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if !ok {
                HStack(spacing: 10) {
                    Button("Grant") {
                        grant()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("System Settings") {
                        openSystemSettings()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }
}
