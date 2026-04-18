//
//  ToolsSettingsView.swift
//  Hivecrew
//
//  Agent tools configuration: web search, image generation, and skills
//

import SwiftUI
import SwiftData

/// Tools settings tab - web search, image generation, and skill matching
struct ToolsSettingsView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.modelContext) private var modelContext
    @Query private var providers: [LLMProviderRecord]

    // Web search
    @AppStorage("searchEngine") private var searchEngine: String = "duckduckgo"
    @AppStorage("defaultResultCount") private var defaultResultCount: Int = 10
    @State private var searchAPIKey: String = ""
    @State private var serpAPIKey: String = ""
    @State private var showSearchAPIKey = false
    @State private var showSerpAPIKey = false

    // Image generation
    @AppStorage("imageGenerationEnabled") private var imageGenerationEnabled = false
    @AppStorage("imageGenerationProvider") private var imageGenerationProvider: String = "openRouter"
    @AppStorage("imageGenerationModel") private var imageGenerationModel: String = ImageGenerationAvailability.defaultOpenRouterModel

    // Skills
    @AppStorage("automaticSkillMatching") private var automaticSkillMatching = true

    private var hasSearchAPIKey: Bool { !searchAPIKey.isEmpty }
    private var hasSerpAPIKey: Bool { !serpAPIKey.isEmpty }

    var body: some View {
        Form {
            webSearchSection
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
    }

    // MARK: - Web Search Section

    private var webSearchSection: some View {
        Section("Web Search") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Search Provider", selection: $searchEngine) {
                    Text("Google (free, scraping)").tag("google")
                    Text("DuckDuckGo (free, scraping)").tag("duckduckgo")
                    Divider()
                    Text("SearchAPI (paid)").tag("searchapi")
                    Text("SerpAPI (paid)").tag("serpapi")
                }
                .pickerStyle(.menu)

                if searchEngine == "searchapi" {
                    apiKeyField(label: LocalizedStringResource("SearchAPI Key"), key: $searchAPIKey, showKey: $showSearchAPIKey, hasKey: hasSearchAPIKey)
                }
                if searchEngine == "serpapi" {
                    apiKeyField(label: LocalizedStringResource("SerpAPI Key"), key: $serpAPIKey, showKey: $showSerpAPIKey, hasKey: hasSerpAPIKey)
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
    private func apiKeyField(label: LocalizedStringResource, key: Binding<String>, showKey: Binding<Bool>, hasKey: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(label)
                Image(systemName: hasKey ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(hasKey ? .green : .orange)
                    .font(.caption)
                Spacer()
            }
            HStack(spacing: 8) {
                if showKey.wrappedValue {
                    TextField("", text: key).textFieldStyle(.roundedBorder)
                } else {
                    SecureField("", text: key).textFieldStyle(.roundedBorder)
                }
                Button { showKey.wrappedValue.toggle() } label: {
                    Image(systemName: showKey.wrappedValue ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    // MARK: - Image Generation Section

    private var imageGenerationSection: some View {
        Section("Image Generation") {
            VStack(alignment: .leading, spacing: 12) {
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
                    Picker("Provider", selection: $imageGenerationProvider) {
                        Text("OpenRouter").tag("openRouter")
                        Text("Google Gemini").tag("gemini")
                    }
                    .pickerStyle(.segmented)

                    if imageGenerationProvider == "openRouter" {
                        openRouterConfigView
                    } else {
                        geminiConfigView
                    }

                    Divider()

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
            HStack(spacing: 4) {
                Image(systemName: hasOpenRouterProvider ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(hasOpenRouterProvider ? .green : .orange)
                Text(
                    hasOpenRouterProvider
                        ? String(localized: "Using OpenRouter provider from Providers settings")
                        : String(localized: "No OpenRouter provider configured. Add one in the Providers tab.")
                )
                    .font(.caption)
                    .foregroundStyle(hasOpenRouterProvider ? Color.secondary : Color.orange)
            }
        }
        .padding(.vertical, 4)
    }

    private var geminiConfigView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: hasGeminiProvider ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(hasGeminiProvider ? .green : .orange)
                Text(
                    hasGeminiProvider
                        ? String(localized: "Using Google AI Studio provider from Providers settings")
                        : String(localized: "No Google AI Studio provider configured. Add one in the Providers tab.")
                )
                    .font(.caption)
                    .foregroundStyle(hasGeminiProvider ? Color.secondary : Color.orange)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Skills Section

    private var skillsSection: some View {
        Section("Agent Skills") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Skills")
                        Text("Reusable instructions that enhance agent capabilities")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Manage Skills...") { openWindow(id: "skills-window") }
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

    // MARK: - Computed Properties

    private var modelHelpText: String {
        imageGenerationProvider == "openRouter"
            ? String(localized: "e.g., google/gemini-3.1-flash-image-preview, google/gemini-3-pro-image-preview")
            : String(localized: "e.g., gemini-3.1-flash-image-preview, gemini-3-pro-image-preview")
    }

    private var hasOpenRouterProvider: Bool {
        ImageGenerationAvailability.hasConfiguredProvider(type: .openRouter, providers: providers)
    }

    private var hasGeminiProvider: Bool {
        ImageGenerationAvailability.hasConfiguredProvider(type: .gemini, providers: providers)
    }

    private var isProviderConfigured: Bool {
        imageGenerationProvider == "openRouter" ? hasOpenRouterProvider : hasGeminiProvider
    }

    // MARK: - Helpers

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
    ToolsSettingsView()
}
