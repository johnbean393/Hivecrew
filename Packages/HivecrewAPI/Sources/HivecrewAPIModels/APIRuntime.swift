//
//  APIRuntime.swift
//  HivecrewAPI
//
//  API-level runtime targeting and metadata types.
//

import Foundation

// MARK: - Runtime Target

public enum APIRuntimeTarget: String, Codable, Sendable {
    case automatic
    case fast
    case app
    case isolatedVM
}

// MARK: - Runtime Kind

public enum APIAgentRuntimeKind: String, Codable, Sendable {
    case fast
    case app
    case isolatedVM
}

// MARK: - Migration Event

public struct APIRuntimeMigrationEvent: Codable, Sendable {
    public let id: String
    public let taskId: String
    public let sessionId: String?
    public let sourceRuntime: APIAgentRuntimeKind
    public let destinationRuntime: APIAgentRuntimeKind
    public let reason: String
    public let createdAt: Date

    public init(
        id: String,
        taskId: String,
        sessionId: String? = nil,
        sourceRuntime: APIAgentRuntimeKind,
        destinationRuntime: APIAgentRuntimeKind,
        reason: String,
        createdAt: Date
    ) {
        self.id = id
        self.taskId = taskId
        self.sessionId = sessionId
        self.sourceRuntime = sourceRuntime
        self.destinationRuntime = destinationRuntime
        self.reason = reason
        self.createdAt = createdAt
    }
}

// MARK: - Setup Requirement

public struct APITaskSetupRequirement: Codable, Sendable {
    public let runtimeKind: APIAgentRuntimeKind
    public let reason: String
    public let deviceId: String?
    public let userFacingMessage: String

    public init(
        runtimeKind: APIAgentRuntimeKind,
        reason: String,
        deviceId: String? = nil,
        userFacingMessage: String
    ) {
        self.runtimeKind = runtimeKind
        self.reason = reason
        self.deviceId = deviceId
        self.userFacingMessage = userFacingMessage
    }
}
