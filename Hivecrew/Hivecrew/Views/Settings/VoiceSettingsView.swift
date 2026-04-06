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

    private var isProviderConfigured: Bool {
        guard let type = VoiceProviderType(rawValue: voiceProviderType) else {
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
                }
                .pickerStyle(.segmented)
                .onChange(of: voiceProviderType) { _, newValue in
                    if let type = VoiceProviderType(rawValue: newValue) {
                        selectedModel = VoiceAvailability.defaultModel(for: type)
                    }
                }

                geminiConfigStatus

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Picker("Model", selection: $selectedModel) {
                        Text("gemini-3.1-flash-live-preview").tag("gemini-3.1-flash-live-preview")
                    }

                    Text("The live preview model for real-time voice conversations.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var geminiConfigStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: hasGeminiProvider ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(hasGeminiProvider ? .green : .orange)
                Text(hasGeminiProvider
                     ? "Using Google AI Studio provider from Providers settings"
                     : "No Google AI Studio provider configured. Add one in the Providers tab.")
                    .font(.caption)
                    .foregroundStyle(hasGeminiProvider ? Color.secondary : Color.orange)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Advanced Section

    private var advancedSection: some View {
        Section("Advanced") {
            Picker("Media Resolution", selection: $mediaResolutionRaw) {
                ForEach(VoiceSessionConfig.MediaResolution.allCases) { res in
                    Text(res.rawValue.capitalized).tag(res.rawValue)
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
