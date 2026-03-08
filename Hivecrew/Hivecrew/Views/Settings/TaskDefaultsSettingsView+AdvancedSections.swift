import SwiftUI

extension TaskDefaultsSettingsView {
    var webToolsSection: some View {
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
                    apiKeyField(label: "SearchAPI Key", key: $searchAPIKey, showKey: $showSearchAPIKey, hasKey: hasSearchAPIKey)
                }
                if searchEngine == "serpapi" {
                    apiKeyField(label: "SerpAPI Key", key: $serpAPIKey, showKey: $showSerpAPIKey, hasKey: hasSerpAPIKey)
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
    func apiKeyField(label: String, key: Binding<String>, showKey: Binding<Bool>, hasKey: Bool) -> some View {
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

    var skillsSection: some View {
        Section("Agent Skills") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Skills").font(.headline)
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

    var imageGenerationSection: some View {
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

    var openRouterConfigView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: hasOpenRouterProvider ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(hasOpenRouterProvider ? .green : .orange)
                Text(hasOpenRouterProvider ? "Using OpenRouter provider from Providers settings" : "No OpenRouter provider configured. Add one in the Providers tab.")
                    .font(.caption)
                    .foregroundStyle(hasOpenRouterProvider ? Color.secondary : Color.orange)
            }
        }
        .padding(.vertical, 4)
    }

    var geminiConfigView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: hasGeminiProvider ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(hasGeminiProvider ? .green : .orange)
                Text(hasGeminiProvider ? "Using Google AI Studio provider from Providers settings" : "No Google AI Studio provider configured. Add one in the Providers tab.")
                    .font(.caption)
                    .foregroundStyle(hasGeminiProvider ? Color.secondary : Color.orange)
            }
        }
        .padding(.vertical, 4)
    }

    var modelHelpText: String {
        imageGenerationProvider == "openRouter"
            ? "e.g., google/gemini-3.1-flash-image-preview, google/gemini-3-pro-image-preview"
            : "e.g., gemini-3.1-flash-image-preview, gemini-3-pro-image-preview"
    }

    var hasOpenRouterProvider: Bool {
        ImageGenerationAvailability.hasConfiguredProvider(type: .openRouter, providers: providers)
    }

    var hasGeminiProvider: Bool {
        ImageGenerationAvailability.hasConfiguredProvider(type: .gemini, providers: providers)
    }

    var isProviderConfigured: Bool {
        imageGenerationProvider == "openRouter" ? hasOpenRouterProvider : hasGeminiProvider
    }
}
