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
    
    /// Keychain service identifier
    private let keychainService = "com.hivecrew.credentials"
    
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
        return tokenMap[uuid]
    }
    
    /// Substitute all UUID tokens in text with their real values
    func substituteTokens(in text: String) -> String {
        var result = text
        
        // UUID regex pattern
        let uuidPattern = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        
        guard let regex = try? NSRegularExpression(pattern: uuidPattern, options: []) else {
            return text
        }
        
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        
        // Process matches in reverse order to maintain correct indices
        for match in matches.reversed() {
            guard let swiftRange = Range(match.range, in: result) else { continue }
            let uuidString = String(result[swiftRange])
            
            if let replacement = resolveToken(uuidString) {
                result.replaceSubrange(swiftRange, with: replacement)
            }
        }
        
        return result
    }
    
    /// Check if text contains any credential tokens
    func containsCredentialTokens(in text: String) -> Bool {
        let uuidPattern = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        
        guard let regex = try? NSRegularExpression(pattern: uuidPattern, options: []) else {
            return false
        }
        
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        
        for match in matches {
            guard let swiftRange = Range(match.range, in: text) else { continue }
            let uuidString = String(text[swiftRange])
            if let uuid = UUID(uuidString: uuidString), tokenMap[uuid] != nil {
                return true
            }
        }
        
        return false
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
        
        let username = tokenMap[credential.usernameToken]
        let password = tokenMap[credential.passwordToken]
        
        return (username, password)
    }
    
    // MARK: - Persistence
    
    private func loadCredentials() {
        // Load credential metadata from UserDefaults
        if let data = UserDefaults.standard.data(forKey: credentialsKey),
           let decoded = try? JSONDecoder().decode([StoredCredential].self, from: data) {
            credentials = decoded
            
            // Load values from Keychain into token map
            for credential in credentials {
                if let username = loadFromKeychain(forToken: credential.usernameToken) {
                    tokenMap[credential.usernameToken] = username
                }
                if let password = loadFromKeychain(forToken: credential.passwordToken) {
                    tokenMap[credential.passwordToken] = password
                }
            }
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
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        
        // Add new item
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
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
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
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
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw CredentialManagerError.keychainError(status)
        }
    }
}
