//
//  APIConfiguration.swift
//  HivecrewAPI
//
//  Configuration for the API server
//

import Foundation

/// Configuration for the Hivecrew REST API server
public struct APIConfiguration: Sendable {
    /// Whether the API server is enabled
    public var isEnabled: Bool
    
    /// Port to listen on (default: 5482)
    public var port: Int
    
    /// Host to bind to (default: 127.0.0.1 for localhost only)
    public var host: String
    
    /// API key for authentication (nil if not set)
    public var apiKey: String?
    
    /// Maximum file upload size in bytes (default: 100MB)
    public var maxFileSize: Int
    
    /// Maximum total upload size per task in bytes (default: 500MB)
    public var maxTotalUploadSize: Int
    
    public init(
        isEnabled: Bool = true,
        port: Int = 5482,
        host: String = "127.0.0.1",
        apiKey: String? = nil,
        maxFileSize: Int = 100 * 1024 * 1024,
        maxTotalUploadSize: Int = 500 * 1024 * 1024
    ) {
        self.isEnabled = isEnabled
        self.port = port
        self.host = host
        self.apiKey = apiKey
        self.maxFileSize = maxFileSize
        self.maxTotalUploadSize = maxTotalUploadSize
    }
    
    /// Load configuration from UserDefaults
    public static func load() -> APIConfiguration {
        let defaults = UserDefaults.standard
        
        return APIConfiguration(
            isEnabled: defaults.bool(forKey: "apiServerEnabled"),
            port: defaults.integer(forKey: "apiServerPort").nonZeroOrDefault(5482),
            host: defaults.string(forKey: "apiServerHost") ?? "127.0.0.1",
            apiKey: nil, // Loaded from Keychain separately
            maxFileSize: defaults.integer(forKey: "apiMaxFileSize").nonZeroOrDefault(100 * 1024 * 1024),
            maxTotalUploadSize: defaults.integer(forKey: "apiMaxTotalUploadSize").nonZeroOrDefault(500 * 1024 * 1024)
        )
    }
    
    /// Save configuration to UserDefaults
    public func save() {
        let defaults = UserDefaults.standard
        defaults.set(isEnabled, forKey: "apiServerEnabled")
        defaults.set(port, forKey: "apiServerPort")
        defaults.set(host, forKey: "apiServerHost")
        defaults.set(maxFileSize, forKey: "apiMaxFileSize")
        defaults.set(maxTotalUploadSize, forKey: "apiMaxTotalUploadSize")
    }
}

// MARK: - Helper Extensions

private extension Int {
    func nonZeroOrDefault(_ defaultValue: Int) -> Int {
        self != 0 ? self : defaultValue
    }
}
