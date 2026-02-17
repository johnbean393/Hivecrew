//
//  APIKeyManager.swift
//  Hivecrew
//
//  Manages API key generation and Keychain storage
//

import Combine
import Foundation
import Security

/// Manages the Hivecrew REST API key
enum APIKeyManager {
    
    private static let unifiedService = "com.pattonium.hivecrew"
    private static let legacyServices = ["com.pattonium.api"]
    private static let keychainKey = "com.pattonium.api-key"
    
    /// Generate a new API key
    /// Format: hc_ prefix + 32 random alphanumeric characters
    static func generateAPIKey() -> String {
        let characters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        let randomPart = String((0..<32).map { _ in characters.randomElement()! })
        return "hc_\(randomPart)"
    }
    
    /// Retrieve the API key from Keychain
    static func retrieveAPIKey() -> String? {
        if let key = retrieveFromService(unifiedService) {
            return key
        }
        
        for legacyService in legacyServices {
            if let legacyKey = retrieveFromService(legacyService) {
                _ = storeAPIKey(legacyKey)
                return legacyKey
            }
        }
        
        return nil
    }
    
    /// Store the API key in Keychain
    @discardableResult
    static func storeAPIKey(_ key: String) -> Bool {
        // Delete any existing key first
        deleteAPIKey()
        
        guard let data = key.data(using: .utf8) else { return false }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: unifiedService,
            kSecAttrAccount as String: keychainKey,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }
    
    /// Delete the API key from Keychain
    @discardableResult
    static func deleteAPIKey() -> Bool {
        var success = true
        let services = [unifiedService] + legacyServices
        
        for service in services {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: keychainKey
            ]
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                success = false
            }
        }
        
        return success
    }
    
    /// Check if an API key exists
    static var hasAPIKey: Bool {
        retrieveAPIKey() != nil
    }
    
    /// Generate and store a new API key, returning the generated key
    static func generateAndStoreAPIKey() -> String? {
        let key = generateAPIKey()
        if storeAPIKey(key) {
            return key
        }
        return nil
    }
    
    /// Regenerate the API key (delete old, create new)
    static func regenerateAPIKey() -> String? {
        deleteAPIKey()
        return generateAndStoreAPIKey()
    }
    
    private static func retrieveFromService(_ service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keychainKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        return key
    }
}
