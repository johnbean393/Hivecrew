//
//  APISystemStatus.swift
//  HivecrewAPI
//
//  System status and configuration models
//

import Foundation

/// Agent counts for system status
public struct APIAgentCounts: Codable, Sendable {
    public let running: Int
    public let paused: Int
    public let queued: Int
    public let maxConcurrent: Int
    
    public init(running: Int, paused: Int, queued: Int, maxConcurrent: Int) {
        self.running = running
        self.paused = paused
        self.queued = queued
        self.maxConcurrent = maxConcurrent
    }
}

/// VM counts for system status
public struct APIVMCounts: Codable, Sendable {
    public let active: Int
    public let pending: Int
    public let available: Int
    
    public init(active: Int, pending: Int, available: Int) {
        self.active = active
        self.pending = pending
        self.available = available
    }
}

/// Resource usage for system status
public struct APIResourceUsage: Codable, Sendable {
    public let cpuUsage: Double?
    public let memoryUsedGB: Double?
    public let memoryTotalGB: Double?
    
    public init(cpuUsage: Double? = nil, memoryUsedGB: Double? = nil, memoryTotalGB: Double? = nil) {
        self.cpuUsage = cpuUsage
        self.memoryUsedGB = memoryUsedGB
        self.memoryTotalGB = memoryTotalGB
    }
}

/// Response for GET /system/status
public struct APISystemStatus: Codable, Sendable {
    public let status: String
    public let version: String
    public let uptime: Int
    public let agents: APIAgentCounts
    public let vms: APIVMCounts
    public let resources: APIResourceUsage
    
    public init(
        status: String,
        version: String,
        uptime: Int,
        agents: APIAgentCounts,
        vms: APIVMCounts,
        resources: APIResourceUsage
    ) {
        self.status = status
        self.version = version
        self.uptime = uptime
        self.agents = agents
        self.vms = vms
        self.resources = resources
    }
}

/// Response for GET /system/config
public struct APISystemConfig: Codable, Sendable {
    public let maxConcurrentVMs: Int
    public let defaultTimeoutMinutes: Int
    public let defaultMaxIterations: Int
    public let defaultTemplateId: String?
    public let apiPort: Int
    
    public init(
        maxConcurrentVMs: Int,
        defaultTimeoutMinutes: Int,
        defaultMaxIterations: Int,
        defaultTemplateId: String?,
        apiPort: Int
    ) {
        self.maxConcurrentVMs = maxConcurrentVMs
        self.defaultTimeoutMinutes = defaultTimeoutMinutes
        self.defaultMaxIterations = defaultMaxIterations
        self.defaultTemplateId = defaultTemplateId
        self.apiPort = apiPort
    }
}
