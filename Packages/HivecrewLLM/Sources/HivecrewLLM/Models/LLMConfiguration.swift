//
//  LLMConfiguration.swift
//  HivecrewLLM
//
//  Configuration for an LLM provider connection
//

import Foundation

/// Configuration for connecting to an LLM provider
public struct LLMConfiguration: Sendable, Codable, Equatable {
    /// Unique identifier for this configuration
    public let id: String
    
    /// Human-readable display name
    public let displayName: String
    
    /// Custom base URL for the API endpoint
    /// If nil, uses the default OpenAI API endpoint
    public let baseURL: URL?
    
    /// API key for authentication
    public let apiKey: String
    
    /// Model identifier (e.g., "gpt-5.2", "gpt-4-turbo")
    public let model: String
    
    /// Optional organization ID for OpenAI
    public let organizationId: String?
    
    /// Request timeout interval in seconds
    public let timeoutInterval: TimeInterval
    
    /// Default timeout interval (60 seconds)
    public static let defaultTimeout: TimeInterval = 300.0
    
    public init(
        id: String = UUID().uuidString,
        displayName: String,
        baseURL: URL? = nil,
        apiKey: String,
        model: String,
        organizationId: String? = nil,
        timeoutInterval: TimeInterval = LLMConfiguration.defaultTimeout
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.organizationId = organizationId
        self.timeoutInterval = timeoutInterval
    }
    
    /// Extract host from baseURL if provided
    public var host: String? {
        baseURL?.host
    }
    
    /// Extract port from baseURL if provided
    public var port: Int? {
        baseURL?.port
    }
    
    /// Extract scheme from baseURL if provided (http or https)
    public var scheme: String? {
        baseURL?.scheme
    }
    
    /// Extract path from baseURL if provided
    public var basePath: String? {
        guard let baseURL = baseURL else { return nil }
        let path = baseURL.path
        return path.isEmpty ? nil : path
    }
    
    /// Whether this configuration points to OpenRouter API
    public var isOpenRouter: Bool {
        guard let host = baseURL?.host?.lowercased() else { return false }
        return host.contains("openrouter.ai")
    }
}
