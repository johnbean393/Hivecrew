//
//  VMProvisioningConfig.swift
//  Hivecrew
//
//  Global VM provisioning configuration: environment variables, setup commands, and file injections
//

import Foundation

/// Global configuration for provisioning ephemeral VMs on startup
struct VMProvisioningConfig: Codable, Equatable {
    
    /// Ordered environment variables injected into every shell command
    var environmentVariables: [EnvironmentVariable]
    
    /// Shell commands executed in order after GuestAgent connects, before the agent loop
    var setupCommands: [String]
    
    /// Files from the host to copy into the VM at prescribed paths
    var fileInjections: [FileInjection]
    
    /// An empty configuration with no provisioning
    static let empty = VMProvisioningConfig(
        environmentVariables: [],
        setupCommands: [],
        fileInjections: []
    )
    
    /// Whether this config has any provisioning defined
    var isEmpty: Bool {
        environmentVariables.isEmpty && setupCommands.isEmpty && fileInjections.isEmpty
    }
}

// MARK: - Environment Variable

extension VMProvisioningConfig {
    
    /// A key-value environment variable pair
    struct EnvironmentVariable: Codable, Identifiable, Equatable {
        var id: UUID
        var key: String
        var value: String
        
        init(id: UUID = UUID(), key: String = "", value: String = "") {
            self.id = id
            self.key = key
            self.value = value
        }
    }
}

// MARK: - File Injection

extension VMProvisioningConfig {
    
    /// A file to copy from the host Assets/VM/ directory into the guest VM
    struct FileInjection: Codable, Identifiable, Equatable {
        var id: UUID
        
        /// Name of the file stored in ~/Library/Application Support/Hivecrew/Assets/VM/
        var fileName: String
        
        /// Destination path inside the VM (e.g. ~/Documents/config.yaml)
        var guestPath: String
        
        init(id: UUID = UUID(), fileName: String = "", guestPath: String = "") {
            self.id = id
            self.fileName = fileName
            self.guestPath = guestPath
        }
    }
}
