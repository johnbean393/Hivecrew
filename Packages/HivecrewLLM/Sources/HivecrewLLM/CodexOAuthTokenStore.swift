import Foundation
import Security

public let codexOAuthClientID = "app_EMoamEEZ73f0CkXaXp7hrann"
public let codexOAuthAuthorizationEndpoint = URL(string: "https://auth.openai.com/oauth/authorize")!
public let codexOAuthTokenEndpoint = URL(string: "https://auth.openai.com/oauth/token")!

public struct CodexOAuthTokens: Codable, Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String
    public let idToken: String?
    public let expiresAt: Date

    public init(accessToken: String, refreshToken: String, idToken: String?, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.expiresAt = expiresAt
    }

    public var isExpired: Bool {
        expiresAt <= Date()
    }

    public func shouldRefresh(within seconds: TimeInterval = 120) -> Bool {
        expiresAt.timeIntervalSinceNow <= seconds
    }
}

public enum CodexOAuthTokenStore {
    private static let keychainService = "com.pattonium.hivecrew.codex-oauth"

    @discardableResult
    public static func store(providerId: String, tokens: CodexOAuthTokens) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(tokens) else { return false }

        let account = accountKey(providerId: providerId)
        _ = delete(providerId: providerId)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    public static func retrieve(providerId: String) -> CodexOAuthTokens? {
        let account = accountKey(providerId: providerId)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CodexOAuthTokens.self, from: data)
    }

    @discardableResult
    public static func delete(providerId: String) -> Bool {
        let account = accountKey(providerId: providerId)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func accountKey(providerId: String) -> String {
        "hivecrew.provider.\(providerId).chatgpt_oauth_tokens"
    }
}
