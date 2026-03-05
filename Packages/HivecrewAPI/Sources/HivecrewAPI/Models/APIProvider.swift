//
//  APIProvider.swift
//  HivecrewAPI
//
//  Provider models for API responses
//

import Foundation

public enum APIProviderBackendMode: String, Codable, Sendable, CaseIterable {
    case chatCompletions = "chat_completions"
    case responses = "responses"
    case codexOAuth = "codex_oauth"
}

public enum APIProviderAuthMode: String, Codable, Sendable, CaseIterable {
    case apiKey = "api_key"
    case chatGPTOAuth = "chatgpt_oauth"
}

public enum APIProviderAuthState: String, Codable, Sendable, CaseIterable {
    case unauthenticated = "unauthenticated"
    case pending = "pending"
    case authenticated = "authenticated"
    case failed = "failed"
}

/// Provider summary for list responses
public struct APIProviderSummary: Codable, Sendable {
    public let id: String
    public let displayName: String
    public let baseURL: String
    public let backendMode: APIProviderBackendMode
    public let authMode: APIProviderAuthMode
    public let authState: APIProviderAuthState?
    public let isDefault: Bool
    public let hasAPIKey: Bool
    public let createdAt: Date
    public let lastUsedAt: Date?

    public init(
        id: String,
        displayName: String,
        baseURL: String,
        backendMode: APIProviderBackendMode = .chatCompletions,
        authMode: APIProviderAuthMode = .apiKey,
        authState: APIProviderAuthState? = nil,
        isDefault: Bool,
        hasAPIKey: Bool,
        createdAt: Date,
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.backendMode = backendMode
        self.authMode = authMode
        self.authState = authState
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
    public let backendMode: APIProviderBackendMode
    public let authMode: APIProviderAuthMode
    public let authState: APIProviderAuthState?
    public let isDefault: Bool
    public let hasAPIKey: Bool
    public let organizationId: String?
    public let oauthLoginId: String?
    public let oauthAuthURL: String?
    public let oauthAuthMessage: String?
    public let oauthAuthUpdatedAt: Date?
    public let timeoutInterval: Double
    public let createdAt: Date
    public let lastUsedAt: Date?

    public init(
        id: String,
        displayName: String,
        baseURL: String,
        backendMode: APIProviderBackendMode = .chatCompletions,
        authMode: APIProviderAuthMode = .apiKey,
        authState: APIProviderAuthState? = nil,
        isDefault: Bool,
        hasAPIKey: Bool,
        organizationId: String? = nil,
        oauthLoginId: String? = nil,
        oauthAuthURL: String? = nil,
        oauthAuthMessage: String? = nil,
        oauthAuthUpdatedAt: Date? = nil,
        timeoutInterval: Double,
        createdAt: Date,
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.backendMode = backendMode
        self.authMode = authMode
        self.authState = authState
        self.isDefault = isDefault
        self.hasAPIKey = hasAPIKey
        self.organizationId = organizationId
        self.oauthLoginId = oauthLoginId
        self.oauthAuthURL = oauthAuthURL
        self.oauthAuthMessage = oauthAuthMessage
        self.oauthAuthUpdatedAt = oauthAuthUpdatedAt
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

// MARK: - Provider CRUD/Auth Requests

public struct APICreateProviderRequest: Codable, Sendable {
    public let displayName: String
    public let baseURL: String?
    public let apiKey: String?
    public let organizationId: String?
    public let backendMode: APIProviderBackendMode?
    public let authMode: APIProviderAuthMode?
    public let isDefault: Bool?
    public let timeoutInterval: Double?

    public init(
        displayName: String,
        baseURL: String? = nil,
        apiKey: String? = nil,
        organizationId: String? = nil,
        backendMode: APIProviderBackendMode? = nil,
        authMode: APIProviderAuthMode? = nil,
        isDefault: Bool? = nil,
        timeoutInterval: Double? = nil
    ) {
        self.displayName = displayName
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.organizationId = organizationId
        self.backendMode = backendMode
        self.authMode = authMode
        self.isDefault = isDefault
        self.timeoutInterval = timeoutInterval
    }
}

public struct APIUpdateProviderRequest: Codable, Sendable {
    public let displayName: String?
    public let baseURL: String?
    public let clearBaseURL: Bool?
    public let apiKey: String?
    public let clearAPIKey: Bool?
    public let organizationId: String?
    public let clearOrganizationId: Bool?
    public let backendMode: APIProviderBackendMode?
    public let authMode: APIProviderAuthMode?
    public let isDefault: Bool?
    public let timeoutInterval: Double?

    public init(
        displayName: String? = nil,
        baseURL: String? = nil,
        clearBaseURL: Bool? = nil,
        apiKey: String? = nil,
        clearAPIKey: Bool? = nil,
        organizationId: String? = nil,
        clearOrganizationId: Bool? = nil,
        backendMode: APIProviderBackendMode? = nil,
        authMode: APIProviderAuthMode? = nil,
        isDefault: Bool? = nil,
        timeoutInterval: Double? = nil
    ) {
        self.displayName = displayName
        self.baseURL = baseURL
        self.clearBaseURL = clearBaseURL
        self.apiKey = apiKey
        self.clearAPIKey = clearAPIKey
        self.organizationId = organizationId
        self.clearOrganizationId = clearOrganizationId
        self.backendMode = backendMode
        self.authMode = authMode
        self.isDefault = isDefault
        self.timeoutInterval = timeoutInterval
    }
}

public struct APIProviderAuthStartResponse: Codable, Sendable {
    public let providerId: String
    public let status: APIProviderAuthState
    public let loginId: String?
    public let authURL: String?
    public let message: String?
    public let updatedAt: Date

    public init(
        providerId: String,
        status: APIProviderAuthState,
        loginId: String? = nil,
        authURL: String? = nil,
        message: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.providerId = providerId
        self.status = status
        self.loginId = loginId
        self.authURL = authURL
        self.message = message
        self.updatedAt = updatedAt
    }
}

public struct APIProviderAuthStatusResponse: Codable, Sendable {
    public let providerId: String
    public let status: APIProviderAuthState
    public let loginId: String?
    public let authURL: String?
    public let message: String?
    public let updatedAt: Date?

    public init(
        providerId: String,
        status: APIProviderAuthState,
        loginId: String? = nil,
        authURL: String? = nil,
        message: String? = nil,
        updatedAt: Date? = nil
    ) {
        self.providerId = providerId
        self.status = status
        self.loginId = loginId
        self.authURL = authURL
        self.message = message
        self.updatedAt = updatedAt
    }
}
