//
//  ProviderUtilities.swift
//  Hivecrew
//
//  Shared utilities for LLM provider configuration views
//

import SwiftUI
import HivecrewLLM

// MARK: - Provider Presets

/// Preset LLM provider configurations
struct LLMProviderPreset: Identifiable {
    let id: String
    let name: String
    let baseURL: String
    
    static let all: [LLMProviderPreset] = [
        LLMProviderPreset(id: "openrouter", name: "OpenRouter", baseURL: defaultLLMProviderBaseURLString),
        LLMProviderPreset(id: "moonshot", name: "Moonshot AI", baseURL: "https://api.moonshot.ai/v1"),
        LLMProviderPreset(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1"),
        LLMProviderPreset(id: "anthropic", name: "Anthropic", baseURL: "https://api.anthropic.com/v1"),
        LLMProviderPreset(id: "google", name: "Google AI Studio", baseURL: "https://generativelanguage.googleapis.com/v1beta"),
        LLMProviderPreset(id: "xai", name: "xAI", baseURL: "https://api.xai.com/v1"),
        LLMProviderPreset(id: "lmstudio", name: "LM Studio", baseURL: "http://localhost:1234/v1"),
        LLMProviderPreset(id: "ollama", name: "Ollama", baseURL: "http://localhost:11434/v1"),
    ]
}

// MARK: - Provider URL Picker Menu

/// Reusable menu for selecting from preset provider URLs
struct ProviderURLPickerMenu: View {
    @Binding var baseURL: String
    
    var body: some View {
        Menu {
            ForEach(LLMProviderPreset.all) { preset in
                Button(preset.name) {
                    baseURL = preset.baseURL
                }
            }
        } label: {
            Label("Select Provider", systemImage: "globe")
                .labelStyle(.iconOnly)
        }
    }
}

// MARK: - Connection Test Result

/// Result of testing a provider connection
enum ConnectionTestResult: Equatable {
    case success
    case failure(String)
    
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

// MARK: - Connection Test Result View

/// Displays the result of a connection test
struct ConnectionTestResultView: View {
    let result: ConnectionTestResult
    let style: Style
    
    enum Style {
        case compact   // For onboarding (colored text)
        case detailed  // For settings (secondary text)
    }
    
    var body: some View {
        switch result {
        case .success:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(style == .compact ? "Connected" : "Connection successful")
                    .foregroundStyle(style == .compact ? .green : .secondary)
            }
            .font(style == .compact ? .callout : .body)
            
        case .failure(let message):
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .foregroundStyle(style == .compact ? .red : .secondary)
                    .lineLimit(style == .compact ? 1 : 2)
            }
            .font(style == .compact ? .callout : .body)
        }
    }
}

// MARK: - Provider Connection Tester

/// Utility for testing LLM provider connections
enum ProviderConnectionTester {
    
    /// Test connection to an LLM provider
    /// - Parameters:
    ///   - baseURL: Custom base URL (empty string uses default)
    ///   - apiKey: API key for authentication
    ///   - organizationId: Optional organization ID
    ///   - timeout: Request timeout in seconds
    /// - Returns: The test result
    static func test(
        baseURL: String,
        apiKey: String,
        organizationId: String? = nil,
        timeout: TimeInterval = 15
    ) async -> ConnectionTestResult {
        // Build the API URL
        let apiURL: URL
        if let customBase = baseURL.isEmpty ? nil : URL(string: baseURL) {
            apiURL = customBase.appendingPathComponent("models")
        } else {
            apiURL = defaultLLMProviderBaseURL.appendingPathComponent("models")
        }
        
        // Create request
        var request = URLRequest(url: apiURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let orgId = organizationId, !orgId.isEmpty {
            request.setValue(orgId, forHTTPHeaderField: "OpenAI-Organization")
        }
        request.timeoutInterval = timeout
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure("Invalid response")
            }
            
            switch httpResponse.statusCode {
            case 200:
                return .success
            case 401:
                return .failure("Invalid API key")
            case 403:
                return .failure("Access denied")
            default:
                return .failure("HTTP \(httpResponse.statusCode)")
            }
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}
