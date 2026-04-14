//
//  RemoteAccessKeychain.swift
//  Hivecrew
//
//  Keychain storage for remote access credentials (session JWT, tunnel token, email, subdomain)
//

import Foundation
import Security

/// Manages Keychain storage for remote access credentials
public enum RemoteAccessKeychain {

    private static let unifiedService = "com.pattonium.hivecrew"
    private static let legacyServices = ["com.pattonium.remote-access"]

    // Keychain account keys
    private static let sessionTokenKey = "session-token"
    private static let tunnelTokenKey = "tunnel-token"
    private static let emailKey = "email"
    private static let subdomainKey = "subdomain"
    private static let tunnelIdKey = "tunnel-id"
    private static let clusterTokenKey = "cluster-token"

    // MARK: - Session Token (JWT)

    public static func storeSessionToken(_ token: String) -> Bool {
        store(key: sessionTokenKey, value: token)
    }

    public static func retrieveSessionToken() -> String? {
        retrieve(key: sessionTokenKey)
    }

    public static func deleteSessionToken() -> Bool {
        delete(key: sessionTokenKey)
    }

    // MARK: - Tunnel Token

    public static func storeTunnelToken(_ token: String) -> Bool {
        store(key: tunnelTokenKey, value: token)
    }

    public static func retrieveTunnelToken() -> String? {
        retrieve(key: tunnelTokenKey)
    }

    public static func deleteTunnelToken() -> Bool {
        delete(key: tunnelTokenKey)
    }

    // MARK: - Email

    public static func storeEmail(_ email: String) -> Bool {
        store(key: emailKey, value: email)
    }

    public static func retrieveEmail() -> String? {
        retrieve(key: emailKey)
    }

    public static func deleteEmail() -> Bool {
        delete(key: emailKey)
    }

    // MARK: - Subdomain

    public static func storeSubdomain(_ subdomain: String) -> Bool {
        store(key: subdomainKey, value: subdomain)
    }

    public static func retrieveSubdomain() -> String? {
        retrieve(key: subdomainKey)
    }

    public static func deleteSubdomain() -> Bool {
        delete(key: subdomainKey)
    }

    // MARK: - Tunnel ID

    public static func storeTunnelId(_ tunnelId: String) -> Bool {
        store(key: tunnelIdKey, value: tunnelId)
    }

    public static func retrieveTunnelId() -> String? {
        retrieve(key: tunnelIdKey)
    }

    public static func deleteTunnelId() -> Bool {
        delete(key: tunnelIdKey)
    }

    // MARK: - Cluster Token

    @discardableResult
    public static func storeClusterToken(_ token: String) -> Bool {
        store(key: clusterTokenKey, value: token)
    }

    public static func retrieveClusterToken() -> String? {
        retrieve(key: clusterTokenKey)
    }

    @discardableResult
    public static func deleteClusterToken() -> Bool {
        delete(key: clusterTokenKey)
    }

    // MARK: - Clear All

    /// Remove all remote access credentials from Keychain
    @discardableResult
    public static func clearAll() -> Bool {
        let keys = [sessionTokenKey, tunnelTokenKey, emailKey, subdomainKey, tunnelIdKey,
                    clusterTokenKey]
        var allSuccess = true
        for key in keys {
            if !delete(key: key) {
                allSuccess = false
            }
        }
        return allSuccess
    }

    /// Check if remote access has been set up (has a tunnel token)
    public static var isConfigured: Bool {
        retrieveTunnelToken() != nil
    }

    // MARK: - Generic Keychain Operations

    private static func store(key: String, value: String) -> Bool {
        // Delete existing first
        delete(key: key)

        guard let data = value.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: unifiedService,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    private static func retrieve(key: String) -> String? {
        if let value = retrieve(key: key, fromService: unifiedService) {
            return value
        }

        for legacyService in legacyServices {
            if let legacyValue = retrieve(key: key, fromService: legacyService) {
                _ = store(key: key, value: legacyValue)
                return legacyValue
            }
        }

        return nil
    }

    @discardableResult
    private static func delete(key: String) -> Bool {
        var success = true
        let services = [unifiedService] + legacyServices

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

        return success
    }

    private static func retrieve(key: String, fromService service: String) -> String? {
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
}
