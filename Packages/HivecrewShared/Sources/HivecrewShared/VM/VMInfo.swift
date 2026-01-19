//
//  VMInfo.swift
//  HivecrewShared
//
//  Created by Hivecrew on 1/10/26.
//

import Foundation

/// Information about a virtual machine instance
public struct VMInfo: Codable, Sendable, Identifiable {
    /// Unique identifier for the VM
    public let id: String
    
    /// Display name for the VM
    public var name: String
    
    /// Current status of the VM
    public var status: VMStatus
    
    /// When the VM was created
    public let createdAt: Date
    
    /// When the VM was last used
    public var lastUsedAt: Date?
    
    /// Path to the VM bundle directory
    public let bundlePath: String
    
    /// Configuration of the VM
    public var configuration: VMConfiguration
    
    public init(
        id: String,
        name: String,
        status: VMStatus,
        createdAt: Date,
        lastUsedAt: Date? = nil,
        bundlePath: String,
        configuration: VMConfiguration
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.bundlePath = bundlePath
        self.configuration = configuration
    }
}

/// Extension to support NSSecureCoding for XPC transport
extension VMInfo {
    public func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "id": id,
            "name": name,
            "status": status.rawValue,
            "createdAt": createdAt.timeIntervalSince1970,
            "bundlePath": bundlePath,
            "configuration": configuration.toDictionary()
        ]
        if let lastUsedAt = lastUsedAt {
            dict["lastUsedAt"] = lastUsedAt.timeIntervalSince1970
        }
        return dict
    }
    
    public static func fromDictionary(_ dict: [String: Any]) -> VMInfo? {
        guard let id = dict["id"] as? String,
              let name = dict["name"] as? String,
              let statusRaw = dict["status"] as? Int,
              let status = VMStatus(rawValue: statusRaw),
              let createdAtInterval = dict["createdAt"] as? TimeInterval,
              let bundlePath = dict["bundlePath"] as? String,
              let configDict = dict["configuration"] as? [String: Any],
              let configuration = VMConfiguration.fromDictionary(configDict) else {
            return nil
        }
        
        let lastUsedAt: Date?
        if let lastUsedInterval = dict["lastUsedAt"] as? TimeInterval {
            lastUsedAt = Date(timeIntervalSince1970: lastUsedInterval)
        } else {
            lastUsedAt = nil
        }
        
        return VMInfo(
            id: id,
            name: name,
            status: status,
            createdAt: Date(timeIntervalSince1970: createdAtInterval),
            lastUsedAt: lastUsedAt,
            bundlePath: bundlePath,
            configuration: configuration
        )
    }
}
