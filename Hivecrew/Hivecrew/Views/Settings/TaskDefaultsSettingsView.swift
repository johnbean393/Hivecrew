//
//  TaskDefaultsSettingsView.swift
//  Hivecrew
//
//  Task settings: operating limits, file output, and web tools configuration
//

import SwiftUI
import UniformTypeIdentifiers

/// Tasks settings tab - operating limits, output directory, and web tools
struct TaskDefaultsSettingsView: View {
    @Environment(\.openWindow) private var openWindow
    
    // Task limits
    @AppStorage("defaultTaskTimeoutMinutes") private var defaultTaskTimeoutMinutes = 30
    @AppStorage("defaultMaxIterations") private var defaultMaxIterations = 100
    @AppStorage("outputDirectoryPath") private var outputDirectoryPath: String = ""
    
    // Web tools
    @AppStorage("searchEngine") private var searchEngine: String = "google"
    @AppStorage("defaultResultCount") private var defaultResultCount: Int = 10
    
    // Skills
    @AppStorage("automaticSkillMatching") private var automaticSkillMatching = true
    
    // Notification settings
    @AppStorage("notifyTaskCompleted") private var notifyTaskCompleted = true
    @AppStorage("notifyTaskIncomplete") private var notifyTaskIncomplete = true
    @AppStorage("notifyTaskFailed") private var notifyTaskFailed = true
    @AppStorage("notifyTaskTimedOut") private var notifyTaskTimedOut = true
    @AppStorage("notifyTaskMaxIterations") private var notifyTaskMaxIterations = true
    
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
    
    var body: some View {
        Form {
            limitsSection
            outputSection
            notificationsSection
            webToolsSection
            skillsSection
        }
        .formStyle(.grouped)
        .padding()
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
            }
        }
    }
    
    // MARK: - Output Section
    
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
    
    // MARK: - Web Tools Section
    
    private var webToolsSection: some View {
        Section("Web Search") {
            Picker("Search Provider", selection: $searchEngine) {
                Label {
                    Text("Google")
                } icon: {
                    Image(systemName: "magnifyingglass")
                }
                .tag("google")
                
                Label {
                    Text("DuckDuckGo")
                } icon: {
                    Image(systemName: "shield")
                }
                .tag("duckduckgo")
            }
            .pickerStyle(.inline)
            
            HStack {
                Text("Default Result Count")
                Spacer()
                TextField("", value: $defaultResultCount, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                Text("results")
                    .foregroundStyle(.secondary)
            }
            
            Text("Configure the search engine and default result count for the web_search tool.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
    
    // MARK: - Skills Section
    
    private var skillsSection: some View {
        Section("Agent Skills") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Skills")
                            .font(.headline)
                        Text("Reusable instructions that enhance agent capabilities")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    Button("Manage Skills...") {
                        openWindow(id: "skills-window")
                    }
                }
                
                Divider()
                
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Automatic Skill Matching", isOn: $automaticSkillMatching)
                    Text("Automatically match enabled skills to tasks using AI. When disabled, only explicitly mentioned skills (@skill-name) will be used.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
    
    private var displayPath: String {
        if outputDirectoryPath.isEmpty {
            return "~/Downloads (default)"
        }
        return outputDirectoryPath.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
    
    /// Function to show the output directory in Finder
    private func showInFinder() {
        NSWorkspace.shared.open(effectiveOutputDirectory)
    }
}

#Preview {
    TaskDefaultsSettingsView()
}
