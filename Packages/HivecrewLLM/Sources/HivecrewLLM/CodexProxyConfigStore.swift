import Foundation
import Security

public struct CodexProxyConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var baseURL: String
    public var token: String

    public init(enabled: Bool, baseURL: String, token: String) {
        self.enabled = enabled
        self.baseURL = baseURL
        self.token = token
    }

    public var isActive: Bool {
        enabled && !baseURL.isEmpty && !token.isEmpty
    }
}

public enum CodexProxyConfigStore {
    private static let keychainService = "com.pattonium.hivecrew.codex-proxy"
    private static let accountKey = "hivecrew.codex-proxy-config"

    @discardableResult
    public static func store(_ config: CodexProxyConfig) -> Bool {
        guard let data = try? JSONEncoder().encode(config) else { return false }

        _ = delete()

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: accountKey,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    public static func retrieve() -> CodexProxyConfig? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: accountKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data else {
            return nil
        }

        return try? JSONDecoder().decode(CodexProxyConfig.self, from: data)
    }

    @discardableResult
    public static func delete() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: accountKey
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

// MARK: - URL + Header Resolvers

public func resolvedCodexAPIBaseURL() -> URL {
    guard let config = CodexProxyConfigStore.retrieve(),
          config.isActive,
          let proxyBase = URL(string: config.baseURL) else {
        return codexOAuthBaseURL
    }
    return proxyBase.appendingPathComponent("v1")
}

public func resolvedCodexOAuthTokenEndpointURL() -> URL {
    guard let config = CodexProxyConfigStore.retrieve(),
          config.isActive,
          let proxyBase = URL(string: config.baseURL) else {
        return codexOAuthTokenEndpoint
    }
    return proxyBase.appendingPathComponent("oauth/token")
}

public func resolvedCodexRealtimeBaseURL() -> String? {
    guard let config = CodexProxyConfigStore.retrieve(),
          config.isActive,
          let proxyBase = URL(string: config.baseURL),
          let host = proxyBase.host else {
        return nil
    }
    let scheme = proxyBase.scheme == "http" ? "ws" : "wss"
    let port = proxyBase.port.map { ":\($0)" } ?? ""
    return "\(scheme)://\(host)\(port)/api"
}

public func codexProxyTokenHeader() -> (String, String)? {
    guard let config = CodexProxyConfigStore.retrieve(),
          config.isActive else {
        return nil
    }
    return ("X-Proxy-Token", config.token)
}

public func applyCodexProxyTokenHeader(to request: inout URLRequest) {
    if let (name, value) = codexProxyTokenHeader() {
        request.setValue(value, forHTTPHeaderField: name)
    }
}
