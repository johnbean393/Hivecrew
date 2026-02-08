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
    @Environment(\.openWindow) private var openWindow
    @Environment(\.modelContext) private var modelContext
    @Query private var providers: [LLMProviderRecord]
    
    // Task limits
    @AppStorage("defaultTaskTimeoutMinutes") private var defaultTaskTimeoutMinutes = 30
    @AppStorage("defaultMaxIterations") private var defaultMaxIterations = 100
    @AppStorage("maxCompletionAttempts") private var maxCompletionAttempts = 3
    @AppStorage("outputDirectoryPath") private var outputDirectoryPath: String = ""
    
    // Web tools
    @AppStorage("searchEngine") private var searchEngine: String = "google"
    @AppStorage("defaultResultCount") private var defaultResultCount: Int = 10
    @State private var searchAPIKey: String = ""
    @State private var serpAPIKey: String = ""
    @State private var showSearchAPIKey = false
    @State private var showSerpAPIKey = false
    
    // Skills
    @AppStorage("automaticSkillMatching") private var automaticSkillMatching = true
    
    // Image generation
    @AppStorage("imageGenerationEnabled") private var imageGenerationEnabled = false
    @AppStorage("imageGenerationProvider") private var imageGenerationProvider: String = "openRouter"
    @AppStorage("imageGenerationModel") private var imageGenerationModel: String = "google/gemini-3-pro-image-preview"
    
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
        }
        .onChange(of: searchAPIKey) { _, newValue in
            updateSearchAPIKey(newValue)
        }
        .onChange(of: serpAPIKey) { _, newValue in
            updateSerpAPIKey(newValue)
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
    
    private var webToolsSection: some View {
        Section("Web Search") {
            VStack(alignment: .leading, spacing: 12) {
                // Provider picker - use menu style for compactness
                Picker("Search Provider", selection: $searchEngine) {
                    Text("Google (free, scraping)").tag("google")
                    Text("DuckDuckGo (free, scraping)").tag("duckduckgo")
                    Divider()
                    Text("SearchAPI (paid)").tag("searchapi")
                    Text("SerpAPI (paid)").tag("serpapi")
                }
                .pickerStyle(.menu)
                
                // Show API key field only for paid providers
                if searchEngine == "searchapi" {
                    apiKeyField(
                        label: "SearchAPI Key",
                        key: $searchAPIKey,
                        showKey: $showSearchAPIKey,
                        hasKey: hasSearchAPIKey
                    )
                }
                
                if searchEngine == "serpapi" {
                    apiKeyField(
                        label: "SerpAPI Key",
                        key: $serpAPIKey,
                        showKey: $showSerpAPIKey,
                        hasKey: hasSerpAPIKey
                    )
                }
                
                Divider()
                
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
            }
            
            Text("Google and DuckDuckGo use web scraping (may be rate-limited). SearchAPI and SerpAPI are paid services with higher reliability.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
    
    @ViewBuilder
    private func apiKeyField(label: String, key: Binding<String>, showKey: Binding<Bool>, hasKey: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(label)
                if hasKey {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                if showKey.wrappedValue {
                    TextField("", text: key)
                        .textFieldStyle(.roundedBorder)
                } else {
                    SecureField("", text: key)
                        .textFieldStyle(.roundedBorder)
                }
                Button {
                    showKey.wrappedValue.toggle()
                } label: {
                    Image(systemName: showKey.wrappedValue ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
            }
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
                    Text("Automatically match enabled skills to tasks using AI when no skills are explicitly mentioned via @. When disabled, only explicitly mentioned skills will be used.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
    
    // MARK: - Image Generation Section
    
    private var imageGenerationSection: some View {
        Section("Image Generation") {
            VStack(alignment: .leading, spacing: 12) {
                // Enable toggle with warning if not configured
                HStack {
                    Toggle("Enable Image Generation", isOn: $imageGenerationEnabled)
                    
                    if imageGenerationEnabled && !isProviderConfigured {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help("Provider not configured")
                    }
                }
                
                if imageGenerationEnabled {
                    Divider()
                    
                    // Provider picker
                    Picker("Provider", selection: $imageGenerationProvider) {
                        Text("OpenRouter").tag("openRouter")
                        Text("Google Gemini").tag("gemini")
                    }
                    .pickerStyle(.segmented)
                    
                    // Provider-specific configuration
                    if imageGenerationProvider == "openRouter" {
                        openRouterConfigView
                    } else {
                        geminiConfigView
                    }
                    
                    Divider()
                    
                    // Model ID
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Model:")
                            TextField("", text: $imageGenerationModel)
                                .textFieldStyle(.roundedBorder)
                        }
                        Text(modelHelpText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Text("Allow agents to generate images using AI. Generated images are saved to the VM's images inbox folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    private var openRouterConfigView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if hasOpenRouterProvider {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Using OpenRouter provider from Providers settings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("No OpenRouter provider configured. Add one in the Providers tab.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 4)
    }
    
    private var geminiConfigView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if hasGeminiProvider {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Using Google AI Studio provider from Providers settings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("No Google AI Studio provider configured. Add one in the Providers tab.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 4)
    }
    
    private var modelHelpText: String {
        if imageGenerationProvider == "openRouter" {
            return "e.g., google/gemini-2.5-flash-preview-image-generation, google/gemini-3-pro-image-preview"
        } else {
            return "e.g., gemini-2.5-flash-image, gemini-3-pro-image-preview"
        }
    }
    
    private var hasOpenRouterProvider: Bool {
        providers.contains { provider in
            guard let baseURL = provider.baseURL else { return false }
            return baseURL.lowercased().contains("openrouter.ai") && provider.hasAPIKey
        }
    }
    
    private var hasGeminiProvider: Bool {
        providers.contains { provider in
            guard let baseURL = provider.baseURL else { return false }
            return baseURL.lowercased().contains("generativelanguage.googleapis.com") && provider.hasAPIKey
        }
    }
    
    private var isProviderConfigured: Bool {
        if imageGenerationProvider == "openRouter" {
            return hasOpenRouterProvider
        } else {
            return hasGeminiProvider
        }
    }

    private var hasSearchAPIKey: Bool {
        !searchAPIKey.isEmpty
    }
    
    private var hasSerpAPIKey: Bool {
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
}

#Preview {
    TaskDefaultsSettingsView()
}
