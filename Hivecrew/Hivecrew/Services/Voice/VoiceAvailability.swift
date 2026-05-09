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
import Security
import HivecrewLLM
import HivecrewVoice

enum VoiceProviderType: String, Sendable {
    case gemini = "gemini"
    case openAI = "openai"
    case xAI = "xai"
    case chatGPTOAuth = "chatgpt_oauth"
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
    static let developerVoiceSessionCaptureKey = "developer_voice_session_capture_enabled"

    static let defaultGeminiModel = "gemini-3.1-flash-live-preview"
    static let defaultOpenAIModel = RealtimeVoiceCatalog.defaultModelID(for: .openAIRealtime)
    static let defaultXAIModel = "grok-voice-think-fast-1.0"

    static func defaultModel(for provider: VoiceProviderType) -> String {
        switch provider {
        case .gemini:
            return defaultGeminiModel
        case .xAI:
            return defaultXAIModel
        case .openAI, .chatGPTOAuth:
            return defaultOpenAIModel
        }
    }

    static func defaultVoice(for provider: VoiceProviderType) -> String {
        switch provider {
        case .gemini: return "Leda"
        case .xAI: return "eve"
        case .openAI, .chatGPTOAuth: return "marin"
        }
    }

    struct Credentials {
        let secret: String?
        let baseURL: URL?
        let providerId: String?
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
        case .xAI:
            return .xAIRealtime
        case .openAI, .chatGPTOAuth:
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

    static func getCredentials(modelContext: ModelContext) -> Credentials? {
        autoConfigureIfNeeded(modelContext: modelContext)

        guard let selectedType = selectedProviderFromDefaults() else {
            return nil
        }

        let descriptor = FetchDescriptor<LLMProviderRecord>()
        guard let providers = try? modelContext.fetch(descriptor) else {
            return nil
        }

        for provider in providers {
            guard providerType(for: provider) == selectedType else {
                continue
            }

            switch selectedType {
            case .gemini, .openAI, .xAI:
                guard let apiKey = provider.retrieveAPIKey(),
                      !apiKey.isEmpty else {
                    continue
                }

                return Credentials(
                    secret: apiKey,
                    baseURL: provider.effectiveBaseURL,
                    providerId: provider.id
                )
            case .chatGPTOAuth:
                guard provider.hasStoredOAuthTokens else {
                    continue
                }

                return Credentials(
                    secret: nil,
                    baseURL: nil,
                    providerId: provider.id
                )
            }
        }

        return nil
    }

    // MARK: - Provider Detection

    static func hasConfiguredProvider(type: VoiceProviderType, providers: [LLMProviderRecord]) -> Bool {
        providers.contains { provider in
            providerType(for: provider) == type && hasCredentials(for: provider)
        }
    }

    static func providerType(for provider: LLMProviderRecord) -> VoiceProviderType? {
        if provider.oauthProviderKind == .chatgpt || provider.backendMode == .codexOAuth {
            return .chatGPTOAuth
        }

        let baseURL = provider.effectiveBaseURL.absoluteString.lowercased()
        if baseURL.contains("generativelanguage.googleapis.com") {
            return .gemini
        }
        if baseURL.contains("api.openai.com") {
            return .openAI
        }
        if baseURL.contains("api.x.ai") {
            return .xAI
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

        if let selectedProviderId = defaults.string(forKey: "lastSelectedProviderId")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !selectedProviderId.isEmpty,
           let selectedProvider = providers.first(where: { $0.id == selectedProviderId }),
           providerType(for: selectedProvider) == .chatGPTOAuth,
           hasConfiguredProvider(type: .chatGPTOAuth, providers: providers) {
            return .chatGPTOAuth
        }

        if hasConfiguredProvider(type: .gemini, providers: providers) {
            return .gemini
        }

        if hasConfiguredProvider(type: .openAI, providers: providers) {
            return .openAI
        }

        if hasConfiguredProvider(type: .xAI, providers: providers) {
            return .xAI
        }

        if hasConfiguredProvider(type: .chatGPTOAuth, providers: providers) {
            return .chatGPTOAuth
        }

        return nil
    }

    private static func hasCredentials(for provider: LLMProviderRecord) -> Bool {
        switch providerType(for: provider) {
        case .gemini, .openAI, .xAI:
            guard let apiKey = provider.retrieveAPIKey() else { return false }
            return !apiKey.isEmpty
        case .chatGPTOAuth:
            return provider.hasStoredOAuthTokens
        case .none:
            return false
        }
    }

    private static func normalizedString(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum VoiceIsolationProfileStore {
    private static let keychainService = "com.pattonium.hivecrew.voice"
    private static let keychainAccount = "speaker-isolation-profile"

    static func loadProfile() -> SpeakerIsolationProfile? {
        guard let data = retrieveData() else { return nil }
        return try? JSONDecoder().decode(SpeakerIsolationProfile.self, from: data)
    }

    static func saveProfile(_ profile: SpeakerIsolationProfile) throws {
        let data = try JSONEncoder().encode(profile)
        guard storeData(data) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    @discardableResult
    static func deleteProfile() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func storeData(_ data: Data) -> Bool {
        _ = deleteProfile()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private static func retrieveData() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }
}
