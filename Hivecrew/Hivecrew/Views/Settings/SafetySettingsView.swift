//
//  SafetySettingsView.swift
//  Hivecrew
//
//  Created by Hivecrew on 1/10/26.
//

import SwiftUI

/// Session trace retention policy
enum TraceRetentionPolicy: String, CaseIterable, Identifiable {
    case keepAll = "keep_all"
    case last7Days = "7_days"
    case last30Days = "30_days"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .keepAll: return "Keep all"
        case .last7Days: return "Last 7 days"
        case .last30Days: return "Last 30 days"
        }
    }
    
    var description: String {
        switch self {
        case .keepAll: return "Session traces are never automatically deleted"
        case .last7Days: return "Traces older than 7 days are deleted on launch"
        case .last30Days: return "Traces older than 30 days are deleted on launch"
        }
    }
}

/// Safety settings tab
struct SafetySettingsView: View {
    
    @AppStorage("requireConfirmationForShell") private var requireConfirmationForShell = false
    @AppStorage("traceRetentionPolicy") private var traceRetentionPolicy: String = TraceRetentionPolicy.keepAll.rawValue
    
    private var selectedRetentionPolicy: TraceRetentionPolicy {
        TraceRetentionPolicy(rawValue: traceRetentionPolicy) ?? .keepAll
    }
    
    var body: some View {
        Form {
            permissionsSection
            retentionSection
        }
        .formStyle(.grouped)
        .padding()
    }
    
    // MARK: - Permissions Section
    
    private var permissionsSection: some View {
        Section("Tool Permissions") {
            VStack(alignment: .leading) {
                Toggle("Confirm shell commands", isOn: $requireConfirmationForShell)
                Text("Require user approval before the agent executes shell commands in the VM")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    // MARK: - Retention Section
    
    private var retentionSection: some View {
        Section("Session Traces") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Retention Policy", selection: $traceRetentionPolicy) {
                    ForEach(TraceRetentionPolicy.allCases) { policy in
                        Text(policy.displayName).tag(policy.rawValue)
                    }
                }
                
                Text(selectedRetentionPolicy.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    SafetySettingsView()
}
