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
    
    /// Check if image generation is available and properly configured
    /// - Parameter modelContext: The SwiftData model context to use for fetching providers
    static func isAvailable(modelContext: ModelContext) -> Bool {
        return getStatus(modelContext: modelContext) == .available
    }
    
    /// Get the current configuration status
    /// - Parameter modelContext: The SwiftData model context to use for fetching providers
    static func getStatus(modelContext: ModelContext) -> ImageGenerationStatus {
        // Check if enabled
        guard UserDefaults.standard.bool(forKey: "imageGenerationEnabled") else {
            return .disabled
        }
        
        // Check if model is configured
        let model = UserDefaults.standard.string(forKey: "imageGenerationModel") ?? ""
        guard !model.isEmpty else {
            return .noModel
        }
        
        // Fetch providers from the provided context
        let descriptor = FetchDescriptor<LLMProviderRecord>()
        guard let providers = try? modelContext.fetch(descriptor) else {
            return .noProvider
        }
        
        // Check provider configuration
        let providerType = UserDefaults.standard.string(forKey: "imageGenerationProvider") ?? "openRouter"
        
        switch providerType {
        case "openRouter":
            let hasOpenRouter = providers.contains { provider in
                guard let baseURL = provider.baseURL else { return false }
                return baseURL.lowercased().contains("openrouter.ai") && provider.hasAPIKey
            }
            return hasOpenRouter ? .available : .noProvider
            
        case "gemini":
            let hasGemini = providers.contains { provider in
                guard let baseURL = provider.baseURL else { return false }
                return baseURL.lowercased().contains("generativelanguage.googleapis.com") && provider.hasAPIKey
            }
            return hasGemini ? .available : .noProvider
            
        default:
            return .noProvider
        }
    }
    
    /// Get the credentials for the selected image generation provider
    /// - Parameter modelContext: The SwiftData model context to use for fetching providers
    /// - Returns: Tuple of (apiKey, baseURL) if found
    static func getCredentials(modelContext: ModelContext) -> (apiKey: String, baseURL: URL?)? {
        let providerType = UserDefaults.standard.string(forKey: "imageGenerationProvider") ?? "openRouter"
        
        let descriptor = FetchDescriptor<LLMProviderRecord>()
        guard let providers = try? modelContext.fetch(descriptor) else {
            return nil
        }
        
        let urlSubstring: String
        switch providerType {
        case "openRouter":
            urlSubstring = "openrouter.ai"
        case "gemini":
            urlSubstring = "generativelanguage.googleapis.com"
        default:
            return nil
        }
        
        // Find first matching provider with API key
        for provider in providers {
            if let baseURL = provider.baseURL,
               baseURL.lowercased().contains(urlSubstring),
               let apiKey = provider.retrieveAPIKey(),
               !apiKey.isEmpty {
                return (apiKey, URL(string: baseURL))
            }
        }
        
        return nil
    }
}
