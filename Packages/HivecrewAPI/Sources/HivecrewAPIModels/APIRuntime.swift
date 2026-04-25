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

// MARK: - Runtime Setup Status

public enum APIRuntimeSetupStatus: String, Codable, Sendable {
    case ready
    case unavailable
    case permissionsMissing
    case backendMissing
    case templateMissing
}

// MARK: - Peer Runtime Summary

public struct PeerRuntimeSummary: Codable, Sendable, Hashable {
    public let runtimeKind: APIAgentRuntimeKind
    public let supported: Bool
    public let availableSlots: Int
    public let runningTasks: Int
    public let queuedTasks: Int
    public let setupStatus: APIRuntimeSetupStatus

    public init(
        runtimeKind: APIAgentRuntimeKind,
        supported: Bool,
        availableSlots: Int,
        runningTasks: Int,
        queuedTasks: Int,
        setupStatus: APIRuntimeSetupStatus
    ) {
        self.runtimeKind = runtimeKind
        self.supported = supported
        self.availableSlots = availableSlots
        self.runningTasks = runningTasks
        self.queuedTasks = queuedTasks
        self.setupStatus = setupStatus
    }
}

// MARK: - Runtime Counts (system status)

public struct APIRuntimeCounts: Codable, Sendable {
    public let kind: APIAgentRuntimeKind
    public let supported: Bool
    public let running: Int
    public let queued: Int
    public let available: Int
    public let maxConcurrent: Int
    public let setupStatus: APIRuntimeSetupStatus

    public init(
        kind: APIAgentRuntimeKind,
        supported: Bool,
        running: Int,
        queued: Int,
        available: Int,
        maxConcurrent: Int,
        setupStatus: APIRuntimeSetupStatus
    ) {
        self.kind = kind
        self.supported = supported
        self.running = running
        self.queued = queued
        self.available = available
        self.maxConcurrent = maxConcurrent
        self.setupStatus = setupStatus
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
