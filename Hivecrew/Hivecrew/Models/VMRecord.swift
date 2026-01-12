//
//  VMRecord.swift
//  Hivecrew
//
//  Created by Hivecrew on 1/10/26.
//

import Foundation
import SwiftData

/// SwiftData model for persisting VM metadata in the main app
@Model
final class VMRecord {
    /// Unique identifier matching the XPC service's VM ID
    @Attribute(.unique) var id: String
    
    /// Display name for the VM
    var name: String
    
    /// Status stored as raw value string for compatibility
    var statusRaw: Int
    
    /// When the VM was created
    var createdAt: Date
    
    /// When the VM was last used
    var lastUsedAt: Date?
    
    /// Number of CPU cores allocated
    var cpuCount: Int
    
    /// Memory size in bytes
    var memorySize: UInt64
    
    /// Disk size in bytes
    var diskSize: UInt64
    
    /// Path to the VM bundle directory
    var bundlePath: String
    
    /// Sort order for UI display (lower = higher priority)
    var sortOrder: Int = Int.max
    
    /// Optional notes about the VM
    var notes: String?
    
    init(
        id: String,
        name: String,
        statusRaw: Int = 0,
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil,
        cpuCount: Int = 2,
        memorySize: UInt64 = 4 * 1024 * 1024 * 1024,
        diskSize: UInt64 = 32 * 1024 * 1024 * 1024,
        bundlePath: String,
        sortOrder: Int = Int.max,
        notes: String? = nil
    ) {
        self.id = id
        self.name = name
        self.statusRaw = statusRaw
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.cpuCount = cpuCount
        self.memorySize = memorySize
        self.diskSize = diskSize
        self.bundlePath = bundlePath
        self.sortOrder = sortOrder
        self.notes = notes
    }
    
}
