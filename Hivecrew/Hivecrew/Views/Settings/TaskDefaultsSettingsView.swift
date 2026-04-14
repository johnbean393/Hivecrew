//
//  TaskDefaultsSettingsView.swift
//  Hivecrew
//
//  Task settings: operating limits, file output, safety, and notifications
//

import SwiftUI
import TipKit
import UniformTypeIdentifiers
import HivecrewCore

/// Session trace retention policy
enum TraceRetentionPolicy: String, CaseIterable, Identifiable {
    case keepAll = "keep_all"
    case last7Days = "7_days"
    case last30Days = "30_days"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .keepAll: return String(localized: "Keep all")
        case .last7Days: return String(localized: "Last 7 days")
        case .last30Days: return String(localized: "Last 30 days")
        }
    }
    
    var description: String {
        switch self {
        case .keepAll: return String(localized: "Session traces are never automatically deleted")
        case .last7Days: return String(localized: "Traces older than 7 days are deleted on launch")
        case .last30Days: return String(localized: "Traces older than 30 days are deleted on launch")
        }
    }
}

/// Tasks settings tab - operating limits, output directory, safety, and notifications
struct TaskDefaultsSettingsView: View {
    
    // Task limits
    @AppStorage("defaultTaskTimeoutMinutes") private var defaultTaskTimeoutMinutes = 90
    @AppStorage("defaultMaxIterations") private var defaultMaxIterations = 300
    @AppStorage("maxCompletionAttempts") private var maxCompletionAttempts = 3
    @AppStorage("outputDirectoryPath") private var outputDirectoryPath: String = ""
    
    // Notification settings
    @AppStorage("notifyTaskCompleted") private var notifyTaskCompleted = true
    @AppStorage("notifyTaskIncomplete") private var notifyTaskIncomplete = true
    @AppStorage("notifyTaskFailed") private var notifyTaskFailed = true
    @AppStorage("notifyTaskTimedOut") private var notifyTaskTimedOut = true
    @AppStorage("notifyTaskMaxIterations") private var notifyTaskMaxIterations = true
    
    // Local writeback
    @AppStorage(WritebackAutoApplySettings.attachmentUpdatesKey) private var autoApplyAttachmentUpdates = WritebackAutoApplySettings.defaults.autoApplyAttachmentUpdates
    
    // Safety settings
    @AppStorage("requireConfirmationForShell") private var requireConfirmationForShell = false
    @AppStorage("traceRetentionPolicy") private var traceRetentionPolicy: String = TraceRetentionPolicy.keepAll.rawValue
    
    @State private var showingFolderPicker = false
    
    /// Default output directory (Downloads)
    private var defaultOutputDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
    }
    
    /// The configured output directory, or default if not set
    var effectiveOutputDirectory: URL {
        if outputDirectoryPath.isEmpty {
            return defaultOutputDirectory
        }
        return URL(fileURLWithPath: outputDirectoryPath)
    }
    
    private var selectedRetentionPolicy: TraceRetentionPolicy {
        TraceRetentionPolicy(rawValue: traceRetentionPolicy) ?? .keepAll
    }
    
    var body: some View {
        Form {
            limitsSection
            outputSection
            writebackSection
            safetySection
            notificationsSection
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            syncWritebackDefaults()
        }
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                outputDirectoryPath = url.path
            }
        }
    }
    
    // MARK: - Limits Section
    
    private var limitsSection: some View {
        Section("Operating Limits") {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Default Timeout:")
                        TextField("", value: $defaultTaskTimeoutMinutes, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: defaultTaskTimeoutMinutes) { _, newValue in
                                defaultTaskTimeoutMinutes = min(max(newValue, 2), 480)
                            }
                        Text("min")
                            .foregroundStyle(.secondary)
                    }
                    Text("Maximum duration for agent tasks (2-480 min)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Divider()
                
                VStack(alignment: .leading) {
                    HStack {
                        Text("Max Iterations:")
                        TextField("", value: $defaultMaxIterations, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: defaultMaxIterations) { _, newValue in
                                defaultMaxIterations = min(max(newValue, 10), 500)
                            }
                    }
                    Text("Maximum number of observe-decide-execute cycles (10-500)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Divider()
                
                VStack(alignment: .leading) {
                    HStack {
                        Text("Verification Tries:")
                        TextField("", value: $maxCompletionAttempts, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: maxCompletionAttempts) { _, newValue in
                                maxCompletionAttempts = min(max(newValue, 1), 10)
                            }
                    }
                    Text("Number of verification attempts before ending an agentic loop (1-10)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
    
    // MARK: - Output Section
    
    private let outputDirectoryTip = OutputDirectoryTip()
    
    private var outputSection: some View {
        Section("File Output") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Output Directory")
                            .font(.headline)
                        Text(displayPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    
                    Spacer()
                    
                    Button("Choose...") {
                        showingFolderPicker = true
                    }
                    .popoverTip(outputDirectoryTip, arrowEdge: .trailing)

                }
                .contextMenu {
                    Button("Show in Finder") {
                        showInFinder()
                    }
                }
                
                Text("Files produced by agents will be copied here from the VM's outbox")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    // MARK: - Writeback Section
    
    private var writebackSection: some View {
        Section("Local Writeback") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Automatically apply edits to attached files", isOn: $autoApplyAttachmentUpdates)

                Text("New files and folder-level changes always stay in Review Changes until the user approves them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    // MARK: - Safety Section
    
    private var safetySection: some View {
        Section("Safety & Retention") {
            VStack(alignment: .leading) {
                Toggle("Confirm shell commands", isOn: $requireConfirmationForShell)
                Text("Require user approval before the agent executes shell commands in the VM")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Picker("Trace Retention", selection: $traceRetentionPolicy) {
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
    
    // MARK: - Notifications Section
    
    private var notificationsSection: some View {
        Section("Notifications") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Task Completed", isOn: $notifyTaskCompleted)
                Toggle("Task Incomplete", isOn: $notifyTaskIncomplete)
                Toggle("Task Failed", isOn: $notifyTaskFailed)
                Toggle("Task Timed Out", isOn: $notifyTaskTimedOut)
                Toggle("Task Hit Max Steps", isOn: $notifyTaskMaxIterations)
                
                Text("Choose which task completion events trigger system notifications")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
    }
    
    // MARK: - Helpers
    
    private var displayPath: String {
        if outputDirectoryPath.isEmpty {
            return "~/Downloads (default)"
        }
        return outputDirectoryPath.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
    
    private func showInFinder() {
        NSWorkspace.shared.open(effectiveOutputDirectory)
    }

    private func syncWritebackDefaults() {
        WritebackAutoApplySettings.migrateLegacyDefaultsIfNeeded()
        let settings = WritebackAutoApplySettings.load()
        autoApplyAttachmentUpdates = settings.autoApplyAttachmentUpdates
    }
}

#Preview {
    TaskDefaultsSettingsView()
}
