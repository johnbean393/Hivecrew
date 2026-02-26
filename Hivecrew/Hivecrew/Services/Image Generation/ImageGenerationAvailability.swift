//
//  ImageGenerationAvailability.swift
//  Hivecrew
//
//  Helper for checking if image generation is available and configured
//

import Foundation
import SwiftData

/// Status of image generation configuration
enum ImageGenerationStatus: Equatable {
    case available
    case disabled
    case noProvider
    case noAPIKey
    case noModel
}

/// Helper for checking image generation availability
enum ImageGenerationAvailability {
    private static let imageGenerationEnabledKey = "imageGenerationEnabled"
    private static let imageGenerationProviderKey = "imageGenerationProvider"
    private static let imageGenerationModelKey = "imageGenerationModel"
    
    static let defaultOpenRouterModel = "google/gemini-3.1-flash-image-preview"
    static let defaultGeminiModel = "gemini-3.1-flash-image-preview"
    
    static func defaultModel(for provider: ImageGenerationProvider) -> String {
        switch provider {
        case .openRouter:
            return defaultOpenRouterModel
        case .gemini:
            return defaultGeminiModel
        }
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
        
        let currentModel = normalizedModel(defaults.string(forKey: imageGenerationModelKey))
        if currentModel.isEmpty || didSwitchProvider {
            defaults.set(defaultModel(for: providerToUse), forKey: imageGenerationModelKey)
        }
    }
    
    static func hasConfiguredProvider(type: ImageGenerationProvider, providers: [LLMProviderRecord]) -> Bool {
        providers.contains { provider in
            providerType(for: provider) == type && hasNonEmptyAPIKey(provider)
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
        
        // Check if model is configured
        let model = normalizedModel(UserDefaults.standard.string(forKey: imageGenerationModelKey))
        guard !model.isEmpty else {
            return .noModel
        }
        
        // Fetch providers from the provided context
        let descriptor = FetchDescriptor<LLMProviderRecord>()
        guard let providers = try? modelContext.fetch(descriptor) else {
            return .noProvider
        }
        
        // Check provider configuration
        guard let provider = selectedProviderFromDefaults() else {
            return .noProvider
        }
        
        return hasConfiguredProvider(type: provider, providers: providers) ? .available : .noProvider
    }
    
    /// Get the credentials for the selected image generation provider
    /// - Parameter modelContext: The SwiftData model context to use for fetching providers
    /// - Returns: Tuple of (apiKey, baseURL) if found
    static func getCredentials(modelContext: ModelContext) -> (apiKey: String, baseURL: URL?)? {
        autoConfigureIfNeeded(modelContext: modelContext)
        
        guard let selectedProviderType = selectedProviderFromDefaults() else {
            return nil
        }
        
        let descriptor = FetchDescriptor<LLMProviderRecord>()
        guard let providers = try? modelContext.fetch(descriptor) else {
            return nil
        }
        
        // Find first matching provider with API key
        for provider in providers {
            if providerType(for: provider) == selectedProviderType,
               let apiKey = provider.retrieveAPIKey(),
               !apiKey.isEmpty {
                return (apiKey, provider.effectiveBaseURL)
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
        
        return nil
    }
    
    private static func providerType(for provider: LLMProviderRecord) -> ImageGenerationProvider? {
        let baseURL = provider.effectiveBaseURL.absoluteString.lowercased()
        if baseURL.contains("openrouter.ai") {
            return .openRouter
        }
        if baseURL.contains("generativelanguage.googleapis.com") {
            return .gemini
        }
        return nil
    }
    
    private static func hasNonEmptyAPIKey(_ provider: LLMProviderRecord) -> Bool {
        guard let apiKey = provider.retrieveAPIKey() else {
            return false
        }
        return !apiKey.isEmpty
    }
    
    private static func normalizedModel(_ model: String?) -> String {
        (model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
