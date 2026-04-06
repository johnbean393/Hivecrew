//
//  VoiceSettingsView.swift
//  Hivecrew
//
//  Settings tab for voice mode configuration.
//  Mirrors the image generation settings pattern: voice provider is
//  auto-detected from configured LLM providers (Google AI Studio).
//

import SwiftUI
import SwiftData
import HivecrewVoice

struct VoiceSettingsView: View {

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LLMProviderRecord.displayName) private var providers: [LLMProviderRecord]

    @AppStorage("voice_provider_type") private var voiceProviderType: String = ""
    @AppStorage("voice_model") private var selectedModel: String = VoiceAvailability.defaultGeminiModel
    @AppStorage("voice_media_resolution") private var mediaResolutionRaw: String = "medium"

    private var hasGeminiProvider: Bool {
        VoiceAvailability.hasConfiguredProvider(type: .gemini, providers: providers)
    }

    private var hasOpenAIProvider: Bool {
        VoiceAvailability.hasConfiguredProvider(type: .openAI, providers: providers)
    }

    private var selectedProviderType: VoiceProviderType? {
        VoiceProviderType(rawValue: voiceProviderType)
    }

    private var isProviderConfigured: Bool {
        guard let type = selectedProviderType else {
            return false
        }
        return VoiceAvailability.hasConfiguredProvider(type: type, providers: providers)
    }

    var body: some View {
        Form {
            providerSection
            advancedSection
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            syncDefaults()
        }
        .onChange(of: providers.count) { _, _ in
            syncDefaults()
        }
    }

    // MARK: - Provider Section

    private var providerSection: some View {
        Section("Provider") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Provider", selection: $voiceProviderType) {
                    Text("Google Gemini").tag(VoiceProviderType.gemini.rawValue)
                    Text("OpenAI").tag(VoiceProviderType.openAI.rawValue)
                }
                .pickerStyle(.segmented)
                .onChange(of: voiceProviderType) { oldValue, newValue in
                    if let oldType = VoiceProviderType(rawValue: oldValue) {
                        VoiceAvailability.savePerProviderPreferences(for: oldType)
                    }
                    if let newType = VoiceProviderType(rawValue: newValue) {
                        VoiceAvailability.restorePerProviderPreferences(for: newType)
                        selectedModel = UserDefaults.standard.string(forKey: VoiceAvailability.voiceModelKey)
                            ?? VoiceAvailability.defaultModel(for: newType)
                    }
                }

                switch selectedProviderType {
                case .openAI:
                    openAIConfigStatus
                default:
                    geminiConfigStatus
                }

                Divider()

                modelPicker
            }
        }
    }

    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch selectedProviderType {
            case .openAI:
                Picker("Model", selection: $selectedModel) {
                    Text("gpt-realtime-1.5").tag("gpt-realtime-1.5")
                    Text("gpt-realtime-mini").tag("gpt-realtime-mini")
                }

                Text("OpenAI Realtime speech-to-speech models.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            default:
                Picker("Model", selection: $selectedModel) {
                    Text("gemini-3.1-flash-live-preview").tag("gemini-3.1-flash-live-preview")
                }

                Text("The live preview model for real-time voice conversations.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var geminiConfigStatus: some View {
        providerConfigStatus(
            isConfigured: hasGeminiProvider,
            configuredMessage: "Using Google AI Studio provider from Providers settings",
            missingMessage: "No Google AI Studio provider configured. Add one in the Providers tab."
        )
    }

    private var openAIConfigStatus: some View {
        providerConfigStatus(
            isConfigured: hasOpenAIProvider,
            configuredMessage: "Using OpenAI provider from Providers settings",
            missingMessage: "No OpenAI provider configured. Add one in the Providers tab."
        )
    }

    private func providerConfigStatus(isConfigured: Bool, configuredMessage: String, missingMessage: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: isConfigured ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(isConfigured ? .green : .orange)
                Text(isConfigured ? configuredMessage : missingMessage)
                    .font(.caption)
                    .foregroundStyle(isConfigured ? Color.secondary : Color.orange)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Advanced Section

    @ViewBuilder
    private var advancedSection: some View {
        if selectedProviderType == .gemini {
            Section("Advanced") {
                Picker("Media Resolution", selection: $mediaResolutionRaw) {
                    ForEach(VoiceSessionConfig.MediaResolution.allCases) { res in
                        Text(res.rawValue.capitalized).tag(res.rawValue)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func syncDefaults() {
        VoiceAvailability.autoConfigureIfNeeded(modelContext: modelContext)

        if let type = VoiceAvailability.selectedProviderFromDefaults() {
            voiceProviderType = type.rawValue
        }

        let normalizedModel = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedModel.isEmpty, let type = VoiceProviderType(rawValue: voiceProviderType) {
            selectedModel = VoiceAvailability.defaultModel(for: type)
        }
    }
}
