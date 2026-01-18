//
//  APIProvider.swift
//  HivecrewAPI
//
//  Provider models for API responses
//

import Foundation

/// Provider summary for list responses
public struct APIProviderSummary: Codable, Sendable {
    public let id: String
    public let displayName: String
    public let baseURL: String
    public let isDefault: Bool
    public let hasAPIKey: Bool
    public let createdAt: Date
    public let lastUsedAt: Date?
    
    public init(
        id: String,
        displayName: String,
        baseURL: String,
        isDefault: Bool,
        hasAPIKey: Bool,
        createdAt: Date,
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.isDefault = isDefault
        self.hasAPIKey = hasAPIKey
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }
}

/// Provider details for GET /providers/:id
public struct APIProvider: Codable, Sendable {
    public let id: String
    public let displayName: String
    public let baseURL: String
    public let isDefault: Bool
    public let hasAPIKey: Bool
    public let organizationId: String?
    public let timeoutInterval: Double
    public let createdAt: Date
    public let lastUsedAt: Date?
    
    public init(
        id: String,
        displayName: String,
        baseURL: String,
        isDefault: Bool,
        hasAPIKey: Bool,
        organizationId: String? = nil,
        timeoutInterval: Double,
        createdAt: Date,
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.isDefault = isDefault
        self.hasAPIKey = hasAPIKey
        self.organizationId = organizationId
        self.timeoutInterval = timeoutInterval
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }
}

/// Response for GET /providers
public struct APIProviderListResponse: Codable, Sendable {
    public let providers: [APIProviderSummary]
    
    public init(providers: [APIProviderSummary]) {
        self.providers = providers
    }
}

/// Model information
public struct APIModel: Codable, Sendable {
    public let id: String
    public let name: String
    public let contextLength: Int?
    
    public init(id: String, name: String, contextLength: Int? = nil) {
        self.id = id
        self.name = name
        self.contextLength = contextLength
    }
}

/// Response for GET /providers/:id/models
public struct APIModelListResponse: Codable, Sendable {
    public let models: [APIModel]
    
    public init(models: [APIModel]) {
        self.models = models
    }
}
