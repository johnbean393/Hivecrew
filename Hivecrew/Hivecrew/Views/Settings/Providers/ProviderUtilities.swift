//
//  ProviderUtilities.swift
//  Hivecrew
//
//  Shared utilities for LLM provider configuration views
//

import Foundation
import SwiftUI
import SwiftData
import HivecrewLLM

private enum ModelSelectionDefaultsKeys {
    static let lastSelectedProviderId = "lastSelectedProviderId"
    static let lastSelectedModelId = "lastSelectedModelId"
    static let lastSelectedModelIdsByProvider = "lastSelectedModelIdsByProvider"
}

private func normalizedModelSelectionValue(_ value: String?) -> String {
    (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

extension UserDefaults {
    func persistedModelId(for providerId: String) -> String? {
        let normalizedProviderId = normalizedModelSelectionValue(providerId)
        guard !normalizedProviderId.isEmpty else { return nil }

        if let storedModelId = persistedModelIdsByProvider()[normalizedProviderId],
           !storedModelId.isEmpty {
            return storedModelId
        }

        let currentProviderId = normalizedModelSelectionValue(
            string(forKey: ModelSelectionDefaultsKeys.lastSelectedProviderId)
        )
        guard currentProviderId == normalizedProviderId else { return nil }

        let currentModelId = normalizedModelSelectionValue(
            string(forKey: ModelSelectionDefaultsKeys.lastSelectedModelId)
        )
        return currentModelId.isEmpty ? nil : currentModelId
    }

    func setPersistedModelId(_ modelId: String, for providerId: String) {
        let normalizedProviderId = normalizedModelSelectionValue(providerId)
        guard !normalizedProviderId.isEmpty else { return }

        let normalizedModelId = normalizedModelSelectionValue(modelId)
        var storedModelIds = persistedModelIdsByProvider()

        if normalizedModelId.isEmpty {
            storedModelIds.removeValue(forKey: normalizedProviderId)
        } else {
            storedModelIds[normalizedProviderId] = normalizedModelId
        }

        set(storedModelIds, forKey: ModelSelectionDefaultsKeys.lastSelectedModelIdsByProvider)
    }

    private func persistedModelIdsByProvider() -> [String: String] {
        guard let rawSelections = dictionary(forKey: ModelSelectionDefaultsKeys.lastSelectedModelIdsByProvider) else {
            return [:]
        }

        return rawSelections.reduce(into: [:]) { partialResult, entry in
            guard let modelId = entry.value as? String else { return }
            let normalizedProviderId = normalizedModelSelectionValue(entry.key)
            let normalizedModelId = normalizedModelSelectionValue(modelId)
            guard !normalizedProviderId.isEmpty, !normalizedModelId.isEmpty else { return }
            partialResult[normalizedProviderId] = normalizedModelId
        }
    }
}

func resolveOAuthProviderKind(
    backendMode: LLMBackendMode,
    authMode: LLMAuthMode
) -> LLMOAuthProviderKind? {
    backendMode.oauthProviderKind ?? authMode.oauthProviderKind
}

func defaultProviderDisplayName(for backendMode: LLMBackendMode) -> String {
    switch backendMode.oauthProviderKind {
    case .chatgpt:
        return "ChatGPT OAuth"
    case .kimi:
        return "Kimi Code OAuth"
    case .none:
        return "OpenRouter"
    }
}

func hasStoredOAuthTokens(
    providerId: String,
    providerKind: LLMOAuthProviderKind?
) -> Bool {
    switch providerKind {
    case .chatgpt:
        return CodexOAuthTokenStore.retrieve(providerId: providerId) != nil
    case .kimi:
        return KimiOAuthTokenStore.retrieve(providerId: providerId) != nil
    case .none:
        return false
    }
}

func orderedProviderRecords(_ providers: [LLMProviderRecord]) -> [LLMProviderRecord] {
    providers.sorted { lhs, rhs in
        if let lhsOrder = lhs.sortOrder, let rhsOrder = rhs.sortOrder,
           lhsOrder != rhsOrder {
            return lhsOrder < rhsOrder
        }

        if (lhs.sortOrder != nil) != (rhs.sortOrder != nil) {
            return lhs.sortOrder == nil
        }

        let nameComparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
        if nameComparison != .orderedSame {
            return nameComparison == .orderedAscending
        }

        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }

        return lhs.id < rhs.id
    }
}

func nextProviderSortOrder(in providers: [LLMProviderRecord]) -> Int {
    max(
        providers.compactMap(\.sortOrder).max() ?? -1,
        providers.count - 1
    ) + 1
}

func persistProviderOrder(
    _ providers: [LLMProviderRecord],
    modelContext: ModelContext
) throws {
    for (index, provider) in providers.enumerated() {
        provider.sortOrder = index
    }

    try modelContext.save()
}

func normalizeProviderSortOrdersIfNeeded(modelContext: ModelContext) {
    let descriptor = FetchDescriptor<LLMProviderRecord>()
    guard let providers = try? modelContext.fetch(descriptor),
          providers.contains(where: { $0.sortOrder == nil }) else {
        return
    }

    let orderedProviders = orderedProviderRecords(providers)
    try? persistProviderOrder(orderedProviders, modelContext: modelContext)
}

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
        LLMProviderPreset(id: "google", name: "Google AI Studio", baseURL: "https://generativelanguage.googleapis.com/v1beta/openai"),
        LLMProviderPreset(id: "xai", name: "xAI", baseURL: "https://api.x.ai/v1"),
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
            Label {
                Text(String(localized: "Select Provider"))
            } icon: {
                Image(systemName: "globe")
            }
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

enum ProviderPersistenceError: LocalizedError {
    case apiKeyStoreFailed
    case apiKeyDeleteFailed

    var errorDescription: String? {
        switch self {
        case .apiKeyStoreFailed:
            return String(localized: "Hivecrew couldn't save the API key to the Keychain.")
        case .apiKeyDeleteFailed:
            return String(localized: "Hivecrew couldn't remove the existing API key from the Keychain.")
        }
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
                Text(style == .compact ? String(localized: "Connected") : String(localized: "Connection successful"))
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
        backendMode: LLMBackendMode = .chatCompletions,
        authMode: LLMAuthMode = .apiKey,
        oauthProviderId: String? = nil,
        timeout: TimeInterval = 15
    ) async -> ConnectionTestResult {
        if let oauthKind = backendMode.oauthProviderKind {
            guard let oauthProviderId,
                  hasStoredOAuthTokens(providerId: oauthProviderId, providerKind: oauthKind) else {
                return .failure(String(localized: "Connect \(oauthKind.displayName) first, then test again."))
            }

            let config = LLMConfiguration(
                id: oauthProviderId,
                displayName: defaultProviderDisplayName(for: backendMode),
                baseURL: nil,
                apiKey: "",
                model: backendMode == .codexOAuth ? "gpt-5-codex" : "model-listing-placeholder",
                organizationId: nil,
                backendMode: backendMode,
                authMode: authMode,
                timeoutInterval: timeout
            )
            let client = LLMService.shared.createClient(from: config)
            do {
                _ = try await client.testConnection()
                return .success
            } catch {
                return .failure(error.localizedDescription)
            }
        }

        // Build the API URL
        let apiURL: URL
        if let customBase = normalizedLLMProviderBaseURLString(baseURL).flatMap(URL.init(string:)) {
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
                return .failure(String(localized: "Invalid response"))
            }
            
            switch httpResponse.statusCode {
            case 200:
                return .success
            case 401:
                return .failure(String(localized: "Invalid API key"))
            case 403:
                return .failure(String(localized: "Access denied"))
            default:
                return .failure(String(localized: "HTTP \(httpResponse.statusCode)"))
            }
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}
