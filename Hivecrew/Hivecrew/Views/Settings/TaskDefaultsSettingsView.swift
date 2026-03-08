//
//  TaskDefaultsSettingsView.swift
//  Hivecrew
//
//  Task settings: operating limits, file output, and web tools configuration
//

import SwiftUI
import SwiftData
import TipKit
import UniformTypeIdentifiers

/// Tasks settings tab - operating limits, output directory, and web tools
struct TaskDefaultsSettingsView: View {
    @Environment(\.openWindow) var openWindow
    @Environment(\.modelContext) private var modelContext
    @Query var providers: [LLMProviderRecord]
    
    // Task limits
    @AppStorage("defaultTaskTimeoutMinutes") private var defaultTaskTimeoutMinutes = 90
    @AppStorage("defaultMaxIterations") private var defaultMaxIterations = 300
    @AppStorage("maxCompletionAttempts") private var maxCompletionAttempts = 3
    @AppStorage("outputDirectoryPath") private var outputDirectoryPath: String = ""
    
    // Web tools
    @AppStorage("searchEngine") var searchEngine: String = "duckduckgo"
    @AppStorage("defaultResultCount") var defaultResultCount: Int = 10
    @State var searchAPIKey: String = ""
    @State var serpAPIKey: String = ""
    @State var showSearchAPIKey = false
    @State var showSerpAPIKey = false
    
    // Skills
    @AppStorage("automaticSkillMatching") var automaticSkillMatching = true
    
    // Image generation
    @AppStorage("imageGenerationEnabled") var imageGenerationEnabled = false
    @AppStorage("imageGenerationProvider") var imageGenerationProvider: String = "openRouter"
    @AppStorage("imageGenerationModel") var imageGenerationModel: String = ImageGenerationAvailability.defaultOpenRouterModel
    
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
            imageGenerationSection
            skillsSection
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            loadSearchProviderKeys()
            syncImageGenerationDefaults()
        }
        .onChange(of: searchAPIKey) { _, newValue in
            updateSearchAPIKey(newValue)
        }
        .onChange(of: serpAPIKey) { _, newValue in
            updateSerpAPIKey(newValue)
        }
        .onChange(of: imageGenerationProvider) { _, _ in
            syncImageGenerationDefaults(forceModelReset: true)
        }
        .onChange(of: providers.count) { _, _ in
            syncImageGenerationDefaults()
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
    
    var hasSearchAPIKey: Bool {
        !searchAPIKey.isEmpty
    }
    
    var hasSerpAPIKey: Bool {
        !serpAPIKey.isEmpty
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
    
    private func loadSearchProviderKeys() {
        searchAPIKey = SearchProviderKeychain.retrieveSearchAPIKey() ?? ""
        serpAPIKey = SearchProviderKeychain.retrieveSerpAPIKey() ?? ""
    }
    
    private func updateSearchAPIKey(_ key: String) {
        if key.isEmpty {
            SearchProviderKeychain.deleteSearchAPIKey()
        } else {
            SearchProviderKeychain.storeSearchAPIKey(key)
        }
    }
    
    private func updateSerpAPIKey(_ key: String) {
        if key.isEmpty {
            SearchProviderKeychain.deleteSerpAPIKey()
        } else {
            SearchProviderKeychain.storeSerpAPIKey(key)
        }
    }
    
    private func syncImageGenerationDefaults(forceModelReset: Bool = false) {
        ImageGenerationAvailability.autoConfigureIfNeeded(modelContext: modelContext)
        
        guard let provider = ImageGenerationProvider(rawValue: imageGenerationProvider) else {
            return
        }
        
        let normalizedModel = imageGenerationModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if forceModelReset || normalizedModel.isEmpty {
            imageGenerationModel = ImageGenerationAvailability.defaultModel(for: provider)
        }
        
        let hasExplicitEnablePreference = UserDefaults.standard.object(forKey: "imageGenerationEnabled") != nil
        if isProviderConfigured && (forceModelReset || !hasExplicitEnablePreference) {
            imageGenerationEnabled = true
        }
    }
}

#Preview {
    TaskDefaultsSettingsView()
}
