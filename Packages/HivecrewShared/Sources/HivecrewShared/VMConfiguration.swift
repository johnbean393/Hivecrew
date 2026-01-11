//
//  VMConfiguration.swift
//  HivecrewShared
//
//  Created by Hivecrew on 1/10/26.
//

import Foundation

/// Configuration for creating or updating a virtual machine
public struct VMConfiguration: Codable, Sendable {
    /// Number of CPU cores to allocate
    public var cpuCount: Int
    
    /// Amount of memory in bytes
    public var memorySize: UInt64
    
    /// Disk size in bytes
    public var diskSize: UInt64
    
    /// Optional display name for the VM
    public var displayName: String?
    
    public init(
        cpuCount: Int = 2,
        memorySize: UInt64 = 4 * 1024 * 1024 * 1024, // 4 GB
        diskSize: UInt64 = 64 * 1024 * 1024 * 1024,  // 64 GB
        displayName: String? = nil
    ) {
        self.cpuCount = cpuCount
        self.memorySize = memorySize
        self.diskSize = diskSize
        self.displayName = displayName
    }
    
    /// Memory size in gigabytes for display
    public var memoryGB: Int {
        Int(memorySize / (1024 * 1024 * 1024))
    }
    
    /// Disk size in gigabytes for display
    public var diskGB: Int {
        Int(diskSize / (1024 * 1024 * 1024))
    }
}

/// Extension to support NSSecureCoding for XPC transport
extension VMConfiguration {
    public func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "cpuCount": cpuCount,
            "memorySize": memorySize,
            "diskSize": diskSize
        ]
        if let displayName = displayName {
            dict["displayName"] = displayName
        }
        return dict
    }
    
    public static func fromDictionary(_ dict: [String: Any]) -> VMConfiguration? {
        guard let cpuCount = dict["cpuCount"] as? Int,
              let memorySize = dict["memorySize"] as? UInt64,
              let diskSize = dict["diskSize"] as? UInt64 else {
            return nil
        }
        return VMConfiguration(
            cpuCount: cpuCount,
            memorySize: memorySize,
            diskSize: diskSize,
            displayName: dict["displayName"] as? String
        )
    }
}
