//
//  VoiceProviderAuthentication.swift
//  HivecrewVoice
//
//  Shared auth container for realtime voice providers so apps can inject
//  either static API keys or refreshable bearer-token resolvers.
//

import Foundation

public struct VoiceProviderAuthentication: Sendable {
    public enum Mode: Sendable {
        case apiKey
        case bearerToken
    }

    public let mode: Mode

    private let staticCredential: String?
    private let credentialResolver: (@Sendable () async throws -> String)?

    private init(
        mode: Mode,
        staticCredential: String?,
        credentialResolver: (@Sendable () async throws -> String)?
    ) {
        self.mode = mode
        self.staticCredential = Self.normalizedCredential(staticCredential)
        self.credentialResolver = credentialResolver
    }

    public static func apiKey(_ apiKey: String) -> Self {
        .init(mode: .apiKey, staticCredential: apiKey, credentialResolver: nil)
    }

    public static func bearerToken(_ token: String) -> Self {
        .init(mode: .bearerToken, staticCredential: token, credentialResolver: nil)
    }

    public static func bearerToken(
        resolver: @escaping @Sendable () async throws -> String
    ) -> Self {
        .init(mode: .bearerToken, staticCredential: nil, credentialResolver: resolver)
    }

    public var apiKey: String? {
        guard mode == .apiKey else { return nil }
        return staticCredential
    }

    public var isConfigured: Bool {
        staticCredential != nil || credentialResolver != nil
    }

    func resolveCredential() async throws -> String {
        if let staticCredential {
            return staticCredential
        }

        guard let credentialResolver else {
            throw VoiceProviderAuthenticationError.missingCredential
        }

        let resolved = try await credentialResolver()
        guard let normalized = Self.normalizedCredential(resolved) else {
            throw VoiceProviderAuthenticationError.emptyCredential
        }
        return normalized
    }

    private static func normalizedCredential(_ value: String?) -> String? {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public enum VoiceProviderAuthenticationError: LocalizedError {
    case missingCredential
    case emptyCredential

    public var errorDescription: String? {
        switch self {
        case .missingCredential:
            return "Authentication is required"
        case .emptyCredential:
            return "Authentication credential is empty"
        }
    }
}
