//
//  VMTemplate.swift
//  HivecrewShared
//
//  Created by Hivecrew on 1/11/26.
//

import Foundation

/// Represents a VM template (golden image) that can be used to create new VMs
public struct VMTemplate: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let createdAt: Date
    public let sourceVMId: String?
    
    /// Disk size in bytes
    public let diskSize: UInt64
    
    /// CPU count from the source VM
    public let cpuCount: Int
    
    /// Memory size in bytes
    public let memorySize: UInt64
    
    /// macOS version if known
    public let macOSVersion: String?
    
    public init(
        id: String = UUID().uuidString,
        name: String,
        description: String = "",
        createdAt: Date = Date(),
        sourceVMId: String? = nil,
        diskSize: UInt64,
        cpuCount: Int,
        memorySize: UInt64,
        macOSVersion: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.createdAt = createdAt
        self.sourceVMId = sourceVMId
        self.diskSize = diskSize
        self.cpuCount = cpuCount
        self.memorySize = memorySize
        self.macOSVersion = macOSVersion
    }
    
    /// The bundle path for this template
    public var bundlePath: URL {
        AppPaths.templateBundlePath(id: id)
    }
    
    /// Check if the template files exist
    public var exists: Bool {
        FileManager.default.fileExists(atPath: bundlePath.path)
    }
    
    /// Human-readable disk size
    public var diskSizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: Int64(diskSize), countStyle: .file)
    }
    
    /// Human-readable memory size
    public var memorySizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: Int64(memorySize), countStyle: .memory)
    }
}
