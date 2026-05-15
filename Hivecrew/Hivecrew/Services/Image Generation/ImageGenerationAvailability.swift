//
//  ImageGenerationAvailability.swift
//  Hivecrew
//
//  Helper for checking if image generation is available and configured
//

import Foundation
import SwiftData
import HivecrewLLM

/// Status of image generation configuration
enum ImageGenerationStatus: Equatable {
    case available
    case disabled
    case noProvider
    case noAPIKey
    case noModel
}

struct ImageGenerationCredentials {
    let secret: String?
    let baseURL: URL?
    let providerId: String?
}

/// Helper for checking image generation availability
enum ImageGenerationAvailability {
    private static let imageGenerationEnabledKey = "imageGenerationEnabled"
    private static let imageGenerationProviderKey = "imageGenerationProvider"
    private static let imageGenerationModelKey = "imageGenerationModel"
    
    static let defaultOpenRouterModel = "google/gemini-3.1-flash-image-preview"
    static let defaultGeminiModel = "gemini-3.1-flash-image-preview"
    static let defaultChatGPTOAuthModel = "gpt-5.5"
    
    static func defaultModel(for provider: ImageGenerationProvider) -> String {
        switch provider {
        case .openRouter:
            return defaultOpenRouterModel
        case .gemini:
            return defaultGeminiModel
        case .chatGPTOAuth:
            return defaultChatGPTOAuthModel
        }
    }

    static func resolvedModel(for provider: ImageGenerationProvider, configuredModel: String?) -> String {
        let trimmed = normalizedModel(configuredModel)
        let fallback = defaultModel(for: provider)

        guard !trimmed.isEmpty else {
            return fallback
        }

        guard provider == .chatGPTOAuth else {
            return trimmed
        }

        let lowercased = trimmed.lowercased()
        if lowercased.hasPrefix("gpt-image-") || lowercased == "chatgpt-image-latest" {
            return fallback
        }

        return trimmed
    }
    
    /// Auto-configure image generation defaults when a supported provider is available.
    /// This allows provider setup to automatically enable image generation with a sane model default.
    static func autoConfigureIfNeeded(modelContext: ModelContext) {
        let descriptor = FetchDescriptor<LLMProviderRecord>()
        guard let providers = try? modelContext.fetch(descriptor), !providers.isEmpty else {
            return
        }
        
        guard let providerToUse = selectedOrFallbackProvider(providers: providers) else {
            return
        }
        
        let defaults = UserDefaults.standard
        let previousProvider = defaults.string(forKey: imageGenerationProviderKey)
        let didSwitchProvider = previousProvider != providerToUse.rawValue
        
        if didSwitchProvider {
            defaults.set(providerToUse.rawValue, forKey: imageGenerationProviderKey)
        }
        
        // Only auto-enable when this setting has never been explicitly set.
        if defaults.object(forKey: imageGenerationEnabledKey) == nil {
            defaults.set(true, forKey: imageGenerationEnabledKey)
        }
        
        let resolvedModel = resolvedModel(
            for: providerToUse,
            configuredModel: defaults.string(forKey: imageGenerationModelKey)
        )
        let currentModel = normalizedModel(defaults.string(forKey: imageGenerationModelKey))
        if didSwitchProvider || currentModel != resolvedModel {
            defaults.set(resolvedModel, forKey: imageGenerationModelKey)
        }
    }
    
    static func hasConfiguredProvider(type: ImageGenerationProvider, providers: [LLMProviderRecord]) -> Bool {
        providers.contains { provider in
            providerType(for: provider) == type && hasCredentials(for: provider)
        }
    }
    
    /// Check if image generation is available and properly configured
    /// - Parameter modelContext: The SwiftData model context to use for fetching providers
    static func isAvailable(modelContext: ModelContext) -> Bool {
        return getStatus(modelContext: modelContext) == .available
    }
    
    /// Get the current configuration status
    /// - Parameter modelContext: The SwiftData model context to use for fetching providers
    static func getStatus(modelContext: ModelContext) -> ImageGenerationStatus {
        autoConfigureIfNeeded(modelContext: modelContext)
        
        // Check if enabled
        guard UserDefaults.standard.bool(forKey: imageGenerationEnabledKey) else {
            return .disabled
        }
        
        guard let provider = selectedProviderFromDefaults() else {
            return .noProvider
        }

        // Check if model is configured
        let model = resolvedModel(
            for: provider,
            configuredModel: UserDefaults.standard.string(forKey: imageGenerationModelKey)
        )
        guard !model.isEmpty else {
            return .noModel
        }
        
        // Fetch providers from the provided context
        let descriptor = FetchDescriptor<LLMProviderRecord>()
        guard let providers = try? modelContext.fetch(descriptor) else {
            return .noProvider
        }
        
        return hasConfiguredProvider(type: provider, providers: providers) ? .available : .noProvider
    }
    
    /// Get the credentials for the selected image generation provider
    /// - Parameter modelContext: The SwiftData model context to use for fetching providers
    /// - Returns: Credentials for the selected provider if found
    static func getCredentials(modelContext: ModelContext) -> ImageGenerationCredentials? {
        autoConfigureIfNeeded(modelContext: modelContext)
        
        guard let selectedProviderType = selectedProviderFromDefaults() else {
            return nil
        }
        
        let descriptor = FetchDescriptor<LLMProviderRecord>()
        guard let providers = try? modelContext.fetch(descriptor) else {
            return nil
        }
        
        // Find first matching provider with valid credentials
        for provider in providers {
            guard providerType(for: provider) == selectedProviderType else {
                continue
            }

            switch selectedProviderType {
            case .openRouter, .gemini:
                guard let apiKey = provider.retrieveAPIKey(),
                      !apiKey.isEmpty else {
                    continue
                }

                return ImageGenerationCredentials(
                    secret: apiKey,
                    baseURL: provider.effectiveBaseURL,
                    providerId: provider.id
                )
            case .chatGPTOAuth:
                guard provider.hasStoredOAuthTokens else {
                    continue
                }

                return ImageGenerationCredentials(
                    secret: nil,
                    baseURL: nil,
                    providerId: provider.id
                )
            }
        }
        
        return nil
    }
    
    private static func selectedProviderFromDefaults() -> ImageGenerationProvider? {
        let rawProvider = UserDefaults.standard.string(forKey: imageGenerationProviderKey) ?? ImageGenerationProvider.openRouter.rawValue
        return ImageGenerationProvider(rawValue: rawProvider)
    }
    
    private static func selectedOrFallbackProvider(providers: [LLMProviderRecord]) -> ImageGenerationProvider? {
        let defaults = UserDefaults.standard
        let hasExplicitProviderPreference = defaults.object(forKey: imageGenerationProviderKey) != nil
        let currentProvider = selectedProviderFromDefaults() ?? .openRouter
        
        if hasConfiguredProvider(type: currentProvider, providers: providers) {
            return currentProvider
        }
        
        // Respect explicit provider selection, even when currently unconfigured.
        if hasExplicitProviderPreference {
            return nil
        }
        
        if hasConfiguredProvider(type: .openRouter, providers: providers) {
            return .openRouter
        }
        
        if hasConfiguredProvider(type: .gemini, providers: providers) {
            return .gemini
        }

        if hasConfiguredProvider(type: .chatGPTOAuth, providers: providers) {
            return .chatGPTOAuth
        }
        
        return nil
    }
    
    private static func providerType(for provider: LLMProviderRecord) -> ImageGenerationProvider? {
        if provider.oauthProviderKind == .chatgpt || provider.backendMode == .codexOAuth {
            return .chatGPTOAuth
        }

        let baseURL = provider.effectiveBaseURL.absoluteString.lowercased()
        if baseURL.contains("openrouter.ai") {
            return .openRouter
        }
        if baseURL.contains("generativelanguage.googleapis.com") {
            return .gemini
        }
        return nil
    }
    
    private static func hasCredentials(for provider: LLMProviderRecord) -> Bool {
        switch providerType(for: provider) {
        case .chatGPTOAuth:
            return provider.hasStoredOAuthTokens
        case .openRouter, .gemini:
            guard let apiKey = provider.retrieveAPIKey() else {
                return false
            }
            return !apiKey.isEmpty
        case .none:
            return false
        }
    }
    
    private static func normalizedModel(_ model: String?) -> String {
        (model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
