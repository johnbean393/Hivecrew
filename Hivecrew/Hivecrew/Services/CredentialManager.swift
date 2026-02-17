//
//  CredentialManager.swift
//  Hivecrew
//
//  Manages stored credentials with UUID-based tokens for secure agent authentication
//

import Combine
import Foundation
import Security

// MARK: - Models

/// Represents a stored credential with UUID tokens for each field
struct StoredCredential: Identifiable, Codable, Equatable {
    let id: UUID
    var displayName: String       // e.g., "GitHub", "Work Email"
    var usernameToken: UUID       // UUID token for the username
    var passwordToken: UUID       // UUID token for the password
    
    init(
        id: UUID = UUID(),
        displayName: String,
        usernameToken: UUID = UUID(),
        passwordToken: UUID = UUID()
    ) {
        self.id = id
        self.displayName = displayName
        self.usernameToken = usernameToken
        self.passwordToken = passwordToken
    }
}

/// Result from CSV import operation
struct CredentialImportResult {
    let imported: Int
    let skipped: Int
    let errors: [String]
}

/// Errors from credential operations
enum CredentialManagerError: Error, LocalizedError {
    case keychainError(OSStatus)
    case credentialNotFound
    case invalidCSV(String)
    case duplicateCredential(String)
    
    var errorDescription: String? {
        switch self {
        case .keychainError(let status):
            return "Keychain error: \(status)"
        case .credentialNotFound:
            return "Credential not found"
        case .invalidCSV(let reason):
            return "Invalid CSV: \(reason)"
        case .duplicateCredential(let name):
            return "Credential '\(name)' already exists"
        }
    }
}

// MARK: - CredentialManager

/// Manages stored credentials with Keychain integration for secure storage
class CredentialManager: ObservableObject {
    
    // MARK: - Singleton
    
    static let shared = CredentialManager()
    
    // MARK: - Properties
    
    /// All stored credentials (metadata only, passwords in Keychain)
    @Published private(set) var credentials: [StoredCredential] = []
    
    /// Token to value mapping (loaded from Keychain)
    private var tokenMap: [UUID: String] = [:]
    
    /// UserDefaults key for storing credential metadata
    private let credentialsKey = "storedCredentials"
    
    /// Unified and legacy keychain service identifiers
    private let unifiedKeychainService = "com.pattonium.hivecrew"
    private let legacyKeychainServices = ["com.pattonium.credentials"]
    
    // MARK: - Initialization
    
    private init() {
        loadCredentials()
    }
    
    // MARK: - CRUD Operations
    
    /// Add a new credential
    @discardableResult
    func addCredential(displayName: String, username: String?, password: String) throws -> StoredCredential {
        // Check for duplicates
        if credentials.contains(where: { $0.displayName.lowercased() == displayName.lowercased() }) {
            throw CredentialManagerError.duplicateCredential(displayName)
        }
        
        let credential = StoredCredential(displayName: displayName)
        
        // Store username in Keychain if provided
        if let username = username, !username.isEmpty {
            try storeInKeychain(value: username, forToken: credential.usernameToken)
            tokenMap[credential.usernameToken] = username
        }
        
        // Store password in Keychain
        try storeInKeychain(value: password, forToken: credential.passwordToken)
        tokenMap[credential.passwordToken] = password
        
        // Add to credentials array and save
        credentials.append(credential)
        saveCredentials()
        
        return credential
    }
    
    /// Update an existing credential
    func updateCredential(_ credential: StoredCredential, username: String?, password: String?) throws {
        guard let index = credentials.firstIndex(where: { $0.id == credential.id }) else {
            throw CredentialManagerError.credentialNotFound
        }
        
        // Update username if provided
        if let username = username {
            if username.isEmpty {
                // Remove username
                try deleteFromKeychain(forToken: credential.usernameToken)
                tokenMap.removeValue(forKey: credential.usernameToken)
            } else {
                try storeInKeychain(value: username, forToken: credential.usernameToken)
                tokenMap[credential.usernameToken] = username
            }
        }
        
        // Update password if provided
        if let password = password, !password.isEmpty {
            try storeInKeychain(value: password, forToken: credential.passwordToken)
            tokenMap[credential.passwordToken] = password
        }
        
        // Update display name if changed
        credentials[index] = credential
        saveCredentials()
    }
    
    /// Delete a credential
    func deleteCredential(id: UUID) throws {
        guard let index = credentials.firstIndex(where: { $0.id == id }) else {
            throw CredentialManagerError.credentialNotFound
        }
        
        let credential = credentials[index]
        
        // Remove from Keychain
        try? deleteFromKeychain(forToken: credential.usernameToken)
        try? deleteFromKeychain(forToken: credential.passwordToken)
        
        // Remove from token map
        tokenMap.removeValue(forKey: credential.usernameToken)
        tokenMap.removeValue(forKey: credential.passwordToken)
        
        // Remove from array and save
        credentials.remove(at: index)
        saveCredentials()
    }
    
    /// Get all credentials
    func allCredentials() -> [StoredCredential] {
        return credentials
    }
    
    // MARK: - Token Operations
    
    /// Resolve a token string to its actual value
    func resolveToken(_ tokenString: String) -> String? {
        guard let uuid = UUID(uuidString: tokenString) else { return nil }
        return valueForToken(uuid)
    }
    
    /// Substitute all UUID tokens in text with their real values
    func substituteTokens(in text: String) -> String {
        var result = text
        
        // Resolve credential tokens lazily so app launch/settings open do not trigger
        // mass keychain reads for all stored credentials.
        let allTokens = Set(credentials.flatMap { [$0.usernameToken, $0.passwordToken] })
        
        // Direct substitution: iterate through known credential tokens and replace them.
        for token in allTokens {
            guard let value = valueForToken(token) else { continue }
            let tokenString = token.uuidString
            // Replace all occurrences (case-insensitive since UUIDs can be upper or lower)
            if let range = result.range(of: tokenString, options: .caseInsensitive) {
                result.replaceSubrange(range, with: value)
                // Continue checking in case there are multiple occurrences
                while let nextRange = result.range(of: tokenString, options: .caseInsensitive) {
                    result.replaceSubrange(nextRange, with: value)
                }
            }
        }
        
        return result
    }
    
    /// Check if text contains any credential tokens
    func containsCredentialTokens(in text: String) -> Bool {
        // Check credential metadata tokens only (no keychain access needed).
        for credential in credentials {
            let tokens = [credential.usernameToken, credential.passwordToken]
            for token in tokens {
                if text.range(of: token.uuidString, options: .caseInsensitive) != nil {
                    return true
                }
            }
        }
        return false
    }
    
    private func valueForToken(_ token: UUID) -> String? {
        if let cached = tokenMap[token] {
            return cached
        }
        
        guard let loaded = loadFromKeychain(forToken: token) else {
            return nil
        }
        
        tokenMap[token] = loaded
        return loaded
    }
    
    // MARK: - Agent API
    
    /// Get credentials for the agent (with optional service filter)
    func getCredentialsForAgent(service: String?) -> [StoredCredential] {
        if let service = service {
            return credentials.filter { $0.displayName.localizedCaseInsensitiveContains(service) }
        }
        return credentials
    }
    
    /// Check if a token belongs to a username field
    func isUsernameToken(_ token: UUID) -> Bool {
        return credentials.contains { $0.usernameToken == token }
    }
    
    /// Check if a token belongs to a password field
    func isPasswordToken(_ token: UUID) -> Bool {
        return credentials.contains { $0.passwordToken == token }
    }
    
    /// Get the credential that owns a token
    func credentialForToken(_ token: UUID) -> StoredCredential? {
        return credentials.first { $0.usernameToken == token || $0.passwordToken == token }
    }
    
    /// Get the real username and password for a credential (for authenticated reveal)
    func getRealValues(for credentialId: UUID) -> (username: String?, password: String?)? {
        guard let credential = credentials.first(where: { $0.id == credentialId }) else {
            return nil
        }
        
        let username = valueForToken(credential.usernameToken)
        let password = valueForToken(credential.passwordToken)
        
        return (username, password)
    }
    
    // MARK: - Persistence
    
    private func loadCredentials() {
        // Load credential metadata from UserDefaults.
        // Values are resolved lazily from Keychain when needed.
        if let data = UserDefaults.standard.data(forKey: credentialsKey),
           let decoded = try? JSONDecoder().decode([StoredCredential].self, from: data) {
            credentials = decoded
            tokenMap.removeAll()
            print("CredentialManager: Loaded \(credentials.count) credential records from UserDefaults")
        } else {
            print("CredentialManager: No credentials found in UserDefaults")
        }
        
        // Add default VM credential if no credentials exist
        if credentials.isEmpty {
            addDefaultVMCredential()
        }
    }
    
    /// Add the default VM root/admin credential
    private func addDefaultVMCredential() {
        do {
            try addCredential(
                displayName: "VM superuser",
                username: "superuser",
                password: "hivecrew"
            )
        } catch {
            // Silently fail - user can add it manually if needed
            print("Failed to add default VM credential: \(error)")
        }
    }
    
    private func saveCredentials() {
        if let data = try? JSONEncoder().encode(credentials) {
            UserDefaults.standard.set(data, forKey: credentialsKey)
        }
    }
    
    // MARK: - Keychain Operations
    
    private func storeInKeychain(value: String, forToken token: UUID) throws {
        let key = token.uuidString
        guard let data = value.data(using: .utf8) else { return }
        
        // Delete existing item first
        for service in allKeychainServices {
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key
            ]
            SecItemDelete(deleteQuery as CFDictionary)
        }
        
        // Add new item
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: unifiedKeychainService,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            throw CredentialManagerError.keychainError(status)
        }
    }
    
    private func loadFromKeychain(forToken token: UUID) -> String? {
        let key = token.uuidString
        
        if let value = loadFromKeychain(forToken: key, service: unifiedKeychainService) {
            return value
        }
        
        for legacyService in legacyKeychainServices {
            if let legacyValue = loadFromKeychain(forToken: key, service: legacyService) {
                try? storeInKeychain(value: legacyValue, forToken: token)
                return legacyValue
            }
        }
        
        return nil
    }
    
    private func loadFromKeychain(forToken key: String, service: String) -> String? {
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
    
    private func deleteFromKeychain(forToken token: UUID) throws {
        let key = token.uuidString
        var lastError: OSStatus?
        
        for service in allKeychainServices {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key
            ]
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                lastError = status
            }
        }
        
        if let lastError {
            throw CredentialManagerError.keychainError(lastError)
        }
    }
    
    private var allKeychainServices: [String] {
        [unifiedKeychainService] + legacyKeychainServices
    }
}
