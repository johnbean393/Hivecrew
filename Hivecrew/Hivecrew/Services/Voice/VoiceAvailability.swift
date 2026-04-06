//
//  VoiceAvailability.swift
//  Hivecrew
//
//  Helper for checking if voice mode is available and configured,
//  mirroring ImageGenerationAvailability's pattern of auto-detecting
//  supported providers from LLMProviderRecord entries.
//

import Foundation
import SwiftData
import HivecrewVoice

enum VoiceProviderType: String, Sendable {
    case gemini = "gemini"
    case openAI = "openai"
}

enum VoiceConfigurationStatus: Equatable {
    case available
    case noProvider
    case noAPIKey
}

enum VoiceAvailability {
    static let voiceProviderTypeKey = "voice_provider_type"
    static let voiceModelKey = "voice_model"
    static let voiceVoiceNameKey = "voice_voice_name"
    static let voiceThinkingLevelKey = "voice_thinking_level"
    static let voiceMediaResolutionKey = "voice_media_resolution"

    static let defaultGeminiModel = "gemini-3.1-flash-live-preview"
    static let defaultOpenAIModel = "gpt-realtime-1.5"

    static func defaultModel(for provider: VoiceProviderType) -> String {
        switch provider {
        case .gemini:
            return defaultGeminiModel
        case .openAI:
            return defaultOpenAIModel
        }
    }

    static func defaultVoice(for provider: VoiceProviderType) -> String {
        switch provider {
        case .gemini: return "Leda"
        case .openAI: return "marin"
        }
    }

    // MARK: - Per-Provider Preference Persistence

    private static func perProviderKey(_ baseKey: String, provider: VoiceProviderType) -> String {
        "\(baseKey)_\(provider.rawValue)"
    }

    /// Saves the current voice and model selections under per-provider keys.
    static func savePerProviderPreferences(for provider: VoiceProviderType) {
        let defaults = UserDefaults.standard
        if let model = defaults.string(forKey: voiceModelKey), !model.isEmpty {
            defaults.set(model, forKey: perProviderKey(voiceModelKey, provider: provider))
        }
        if let voice = defaults.string(forKey: voiceVoiceNameKey), !voice.isEmpty {
            defaults.set(voice, forKey: perProviderKey(voiceVoiceNameKey, provider: provider))
        }
    }

    /// Restores per-provider voice and model, falling back to defaults.
    static func restorePerProviderPreferences(for provider: VoiceProviderType) {
        let defaults = UserDefaults.standard
        let model = defaults.string(forKey: perProviderKey(voiceModelKey, provider: provider))
        defaults.set(
            (model?.isEmpty == false) ? model : defaultModel(for: provider),
            forKey: voiceModelKey
        )
        let voice = defaults.string(forKey: perProviderKey(voiceVoiceNameKey, provider: provider))
        defaults.set(
            (voice?.isEmpty == false) ? voice : defaultVoice(for: provider),
            forKey: voiceVoiceNameKey
        )
    }

    static func backend(for type: VoiceProviderType) -> VoiceProviderBackend {
        switch type {
        case .gemini:
            return .geminiLive
        case .openAI:
            return .openAIRealtime
        }
    }

    // MARK: - Auto-configure

    static func autoConfigureIfNeeded(modelContext: ModelContext) {
        let descriptor = FetchDescriptor<LLMProviderRecord>()
        guard let providers = try? modelContext.fetch(descriptor), !providers.isEmpty else {
            return
        }

        guard let providerToUse = selectedOrFallbackProvider(providers: providers) else {
            return
        }

        let defaults = UserDefaults.standard
        let previousRaw = defaults.string(forKey: voiceProviderTypeKey)
        let previousProvider = previousRaw.flatMap(VoiceProviderType.init(rawValue:))
        let didSwitchProvider = previousRaw != providerToUse.rawValue

        if didSwitchProvider {
            if let previousProvider {
                savePerProviderPreferences(for: previousProvider)
            }
            defaults.set(providerToUse.rawValue, forKey: voiceProviderTypeKey)
            restorePerProviderPreferences(for: providerToUse)
        }

        let currentModel = normalizedString(defaults.string(forKey: voiceModelKey))
        if currentModel.isEmpty {
            defaults.set(defaultModel(for: providerToUse), forKey: voiceModelKey)
        }
    }

    // MARK: - Status

    static func isConfigured(modelContext: ModelContext) -> Bool {
        return getStatus(modelContext: modelContext) == .available
    }

    static func getStatus(modelContext: ModelContext) -> VoiceConfigurationStatus {
        autoConfigureIfNeeded(modelContext: modelContext)

        let descriptor = FetchDescriptor<LLMProviderRecord>()
        guard let providers = try? modelContext.fetch(descriptor) else {
            return .noProvider
        }

        guard let providerType = selectedProviderFromDefaults() else {
            return .noProvider
        }

        if !hasConfiguredProvider(type: providerType, providers: providers) {
            return .noProvider
        }

        return .available
    }

    // MARK: - Credentials

    static func getCredentials(modelContext: ModelContext) -> (apiKey: String, baseURL: URL?)? {
        autoConfigureIfNeeded(modelContext: modelContext)

        guard let selectedType = selectedProviderFromDefaults() else {
            return nil
        }

        let descriptor = FetchDescriptor<LLMProviderRecord>()
        guard let providers = try? modelContext.fetch(descriptor) else {
            return nil
        }

        for provider in providers {
            if providerType(for: provider) == selectedType,
               let apiKey = provider.retrieveAPIKey(),
               !apiKey.isEmpty {
                return (apiKey, provider.effectiveBaseURL)
            }
        }

        return nil
    }

    // MARK: - Provider Detection

    static func hasConfiguredProvider(type: VoiceProviderType, providers: [LLMProviderRecord]) -> Bool {
        providers.contains { provider in
            providerType(for: provider) == type && hasNonEmptyAPIKey(provider)
        }
    }

    static func providerType(for provider: LLMProviderRecord) -> VoiceProviderType? {
        let baseURL = provider.effectiveBaseURL.absoluteString.lowercased()
        if baseURL.contains("generativelanguage.googleapis.com") {
            return .gemini
        }
        if baseURL.contains("api.openai.com") {
            return .openAI
        }
        return nil
    }

    // MARK: - Private

    static func selectedProviderFromDefaults() -> VoiceProviderType? {
        guard let raw = UserDefaults.standard.string(forKey: voiceProviderTypeKey) else {
            return nil
        }
        return VoiceProviderType(rawValue: raw)
    }

    private static func selectedOrFallbackProvider(providers: [LLMProviderRecord]) -> VoiceProviderType? {
        let defaults = UserDefaults.standard
        let hasExplicitPreference = defaults.object(forKey: voiceProviderTypeKey) != nil

        if let current = selectedProviderFromDefaults(),
           hasConfiguredProvider(type: current, providers: providers) {
            return current
        }

        if hasExplicitPreference {
            return nil
        }

        if hasConfiguredProvider(type: .gemini, providers: providers) {
            return .gemini
        }

        if hasConfiguredProvider(type: .openAI, providers: providers) {
            return .openAI
        }

        return nil
    }

    private static func hasNonEmptyAPIKey(_ provider: LLMProviderRecord) -> Bool {
        guard let apiKey = provider.retrieveAPIKey() else { return false }
        return !apiKey.isEmpty
    }

    private static func normalizedString(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
