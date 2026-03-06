//
//  LLMProviderRecord.swift
//  Hivecrew
//
//  SwiftData model for persisting LLM provider configurations
//

import Foundation
import Security
import SwiftData
import HivecrewLLM

/// SwiftData model for persisting LLM provider configurations
/// Note: Models are fetched dynamically from the provider's /v1/models endpoint
/// and selected in the prompt bar, not stored per-provider.
@Model
final class LLMProviderRecord {
    /// Unique identifier for this provider
    @Attribute(.unique) var id: String

    /// Human-readable display name
    var displayName: String

    /// Custom base URL for the API endpoint (nil = default OpenRouter)
    var baseURL: String?

    /// Reference to the API key in Keychain
    /// Format: "hivecrew.provider.<id>"
    var apiKeyRef: String

    /// Optional organization ID for OpenAI
    var organizationId: String?

    /// Backend mode for this provider (`chat_completions`, `responses`, `codex_oauth`)
    var backendModeRaw: String?

    /// Authentication mode (`api_key`, `chatgpt_oauth`)
    var authModeRaw: String?

    /// OAuth auth state for this provider
    var oauthAuthStateRaw: String?

    /// Last OAuth login id
    var oauthLoginId: String?

    /// Last OAuth auth URL
    var oauthLastAuthURL: String?

    /// Last OAuth state update time
    var oauthAuthUpdatedAt: Date?

    /// Last OAuth status message/details
    var oauthAuthMessage: String?

    /// Whether this is the default provider
    var isDefault: Bool

    /// When this provider was created
    var createdAt: Date

    /// When this provider was last used
    var lastUsedAt: Date?

    /// Request timeout in seconds
    var timeoutInterval: Double

    init(
        id: String = UUID().uuidString,
        displayName: String,
        baseURL: String? = nil,
        apiKeyRef: String? = nil,
        organizationId: String? = nil,
        backendMode: LLMBackendMode = .chatCompletions,
        authMode: LLMAuthMode = .apiKey,
        oauthAuthState: CodexOAuthAuthState = .unauthenticated,
        oauthLoginId: String? = nil,
        oauthLastAuthURL: String? = nil,
        oauthAuthUpdatedAt: Date? = nil,
        oauthAuthMessage: String? = nil,
        isDefault: Bool = false,
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil,
        timeoutInterval: Double = 120.0
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.apiKeyRef = apiKeyRef ?? "hivecrew.provider.\(id)"
        self.organizationId = organizationId
        self.backendModeRaw = backendMode.rawValue
        self.authModeRaw = authMode.rawValue
        self.oauthAuthStateRaw = oauthAuthState.rawValue
        self.oauthLoginId = oauthLoginId
        self.oauthLastAuthURL = oauthLastAuthURL
        self.oauthAuthUpdatedAt = oauthAuthUpdatedAt
        self.oauthAuthMessage = oauthAuthMessage

        self.isDefault = isDefault
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.timeoutInterval = timeoutInterval
    }

    /// The keychain key for storing/retrieving the API key
    var keychainKey: String {
        apiKeyRef
    }

    /// Parsed base URL
    var parsedBaseURL: URL? {
        guard let baseURL = baseURL else { return nil }
        return URL(string: baseURL)
    }

    /// A display string showing provider name
    var displayLabel: String {
        displayName
    }

    var backendMode: LLMBackendMode {
        get { LLMBackendMode(rawValue: backendModeRaw ?? "") ?? .chatCompletions }
        set { backendModeRaw = newValue.rawValue }
    }

    var authMode: LLMAuthMode {
        get {
            if let stored = LLMAuthMode(rawValue: authModeRaw ?? "") {
                return stored
            }
            return backendMode == .codexOAuth ? .chatGPTOAuth : .apiKey
        }
        set { authModeRaw = newValue.rawValue }
    }

    var oauthAuthState: CodexOAuthAuthState {
        get {
            if let raw = oauthAuthStateRaw, let decoded = CodexOAuthAuthState(rawValue: raw) {
                return decoded
            }
            return .unauthenticated
        }
        set { oauthAuthStateRaw = newValue.rawValue }
    }

    var isOAuthAuthenticated: Bool {
        oauthAuthState == .authenticated
    }

    var oauthAuthURL: URL? {
        guard let oauthLastAuthURL else { return nil }
        return URL(string: oauthLastAuthURL)
    }

    /// The base URL for API calls (either custom or default OpenRouter)
    var effectiveBaseURL: URL {
        if backendMode == .codexOAuth {
            return codexOAuthBaseURL
        }
        return parsedBaseURL ?? defaultLLMProviderBaseURL
    }

    /// Build an LLM configuration for a specific model selection.
    func makeLLMConfiguration(
        model: String,
        apiKey: String,
        reasoningEnabled: Bool? = nil,
        reasoningEffort: String? = nil
    ) -> LLMConfiguration {
        LLMConfiguration(
            id: id,
            displayName: displayName,
            baseURL: backendMode == .codexOAuth ? nil : parsedBaseURL,
            apiKey: apiKey,
            model: model,
            organizationId: organizationId,
            backendMode: backendMode,
            authMode: authMode,
            timeoutInterval: timeoutInterval,
            reasoningEnabled: reasoningEnabled,
            reasoningEffort: reasoningEffort
        )
    }
}

// MARK: - Keychain Integration

extension LLMProviderRecord {
    /// Store an API key in the Keychain for this provider
    @discardableResult
    func storeAPIKey(_ apiKey: String) -> Bool {
        KeychainHelper.save(key: keychainKey, value: apiKey)
    }

    /// Retrieve the API key from the Keychain
    func retrieveAPIKey() -> String? {
        KeychainHelper.retrieve(key: keychainKey)
    }

    /// Delete the API key from the Keychain
    @discardableResult
    func deleteAPIKey() -> Bool {
        KeychainHelper.delete(key: keychainKey)
    }

    /// Check if an API key exists in the Keychain
    var hasAPIKey: Bool {
        retrieveAPIKey() != nil
    }

    @discardableResult
    func storeOAuthTokens(_ tokens: CodexOAuthTokens) -> Bool {
        CodexOAuthTokenStore.store(providerId: id, tokens: tokens)
    }

    func retrieveOAuthTokens() -> CodexOAuthTokens? {
        CodexOAuthTokenStore.retrieve(providerId: id)
    }

    @discardableResult
    func deleteOAuthTokens() -> Bool {
        CodexOAuthTokenStore.delete(providerId: id)
    }
}

// MARK: - Keychain Helper

/// Simple Keychain helper for storing API keys
enum KeychainHelper {
    private static let unifiedService = "com.pattonium.hivecrew"
    private static let legacyServices = ["com.pattonium.llm-providers"]

    private enum CacheEntry {
        case value(String)
        case missing
    }

    private static let cacheLock = NSLock()
    private static var cache: [String: CacheEntry] = [:]

    /// Save a value to the Keychain
    static func save(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        // Delete any existing item first
        delete(key: key, updateCache: false, includeLegacyServices: true)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: unifiedService,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        let success = status == errSecSuccess
        if success {
            setCacheEntry(.value(value), for: key)
        } else {
            clearCacheEntry(for: key)
        }
        return success
    }

    /// Retrieve a value from the Keychain
    static func retrieve(key: String) -> String? {
        if let cached = cacheEntry(for: key) {
            switch cached {
            case .value(let value):
                return value
            case .missing:
                return nil
            }
        }

        if let value = retrieveFromService(key: key, service: unifiedService) {
            setCacheEntry(.value(value), for: key)
            return value
        }

        for legacyService in legacyServices {
            if let value = retrieveFromService(key: key, service: legacyService) {
                _ = save(key: key, value: value)
                setCacheEntry(.value(value), for: key)
                return value
            }
        }

        setCacheEntry(.missing, for: key)
        return nil
    }

    /// Delete a value from the Keychain
    @discardableResult
    static func delete(key: String) -> Bool {
        delete(key: key, updateCache: true, includeLegacyServices: true)
    }

    @discardableResult
    private static func delete(key: String, updateCache: Bool, includeLegacyServices: Bool) -> Bool {
        let services = includeLegacyServices ? [unifiedService] + legacyServices : [unifiedService]
        var success = true

        for service in services {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key
            ]
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                success = false
            }
        }

        if updateCache && success {
            setCacheEntry(.missing, for: key)
        }
        return success
    }

    private static func retrieveFromService(key: String, service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    private static func cacheEntry(for key: String) -> CacheEntry? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache[key]
    }

    private static func setCacheEntry(_ entry: CacheEntry, for key: String) {
        cacheLock.lock()
        cache[key] = entry
        cacheLock.unlock()
    }

    private static func clearCacheEntry(for key: String) {
        cacheLock.lock()
        cache.removeValue(forKey: key)
        cacheLock.unlock()
    }
}
