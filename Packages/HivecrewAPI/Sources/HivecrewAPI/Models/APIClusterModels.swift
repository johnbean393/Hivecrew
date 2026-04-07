//
//  APIClusterModels.swift
//  HivecrewAPI
//
//  Request/response models for cluster endpoints
//

import Foundation

// MARK: - Provider Capability Summary

/// Lightweight summary of a provider's name and model IDs, sent in peer announcements
/// so the coordinator knows which models each machine supports.
public struct PeerProviderSummary: Codable, Sendable, Hashable {
    public let providerName: String
    public let modelIds: [String]
    
    public init(providerName: String, modelIds: [String]) {
        self.providerName = providerName
        self.modelIds = modelIds
    }
}

// MARK: - Inbound (worker → coordinator)

/// A worker announcing its identity and current capacity to the coordinator
public struct PeerAnnouncement: Codable, Sendable {
    public let tunnelId: String
    public let subdomain: String
    public let name: String?
    public let tunnelUrl: String
    public let availableSlots: Int
    public let runningTasks: Int
    public let queuedTasks: Int
    public let providers: [PeerProviderSummary]?
    
    public init(
        tunnelId: String,
        subdomain: String,
        name: String?,
        tunnelUrl: String,
        availableSlots: Int,
        runningTasks: Int,
        queuedTasks: Int,
        providers: [PeerProviderSummary]? = nil
    ) {
        self.tunnelId = tunnelId
        self.subdomain = subdomain
        self.name = name
        self.tunnelUrl = tunnelUrl
        self.availableSlots = availableSlots
        self.runningTasks = runningTasks
        self.queuedTasks = queuedTasks
        self.providers = providers
    }
}

/// A worker pushing a task status change to the coordinator's shadow index
public struct PeerTaskUpdate: Codable, Sendable {
    public let tunnelId: String
    public let taskId: String
    public let task: APITask
    
    public init(tunnelId: String, taskId: String, task: APITask) {
        self.tunnelId = tunnelId
        self.taskId = taskId
        self.task = task
    }
}

/// A worker signaling that it is going offline
public struct PeerDeparture: Codable, Sendable {
    public let tunnelId: String
    
    public init(tunnelId: String) {
        self.tunnelId = tunnelId
    }
}

// MARK: - Outbound (coordinator → web UI)

/// Aggregate cluster status for the web UI
public struct APIClusterStatus: Codable, Sendable {
    public let role: String
    public let totalCapacity: Int
    public let totalRunning: Int
    public let totalQueued: Int
    public let localCapacity: Int
    public let localRunning: Int
    public let peers: [APIClusterPeer]
    
    public init(
        role: String,
        totalCapacity: Int,
        totalRunning: Int,
        totalQueued: Int,
        localCapacity: Int,
        localRunning: Int,
        peers: [APIClusterPeer]
    ) {
        self.role = role
        self.totalCapacity = totalCapacity
        self.totalRunning = totalRunning
        self.totalQueued = totalQueued
        self.localCapacity = localCapacity
        self.localRunning = localRunning
        self.peers = peers
    }
}

/// A single peer's summary for the web UI
public struct APIClusterPeer: Codable, Sendable {
    public let tunnelId: String
    public let subdomain: String
    public let name: String?
    public let status: String
    public let availableSlots: Int
    public let runningTasks: Int
    public let lastSeen: Date
    
    public init(
        tunnelId: String,
        subdomain: String,
        name: String?,
        status: String,
        availableSlots: Int,
        runningTasks: Int,
        lastSeen: Date
    ) {
        self.tunnelId = tunnelId
        self.subdomain = subdomain
        self.name = name
        self.status = status
        self.availableSlots = availableSlots
        self.runningTasks = runningTasks
        self.lastSeen = lastSeen
    }
}
