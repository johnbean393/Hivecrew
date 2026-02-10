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
    
    /// A file to copy from the host into the guest VM
    struct FileInjection: Codable, Identifiable, Equatable {
        var id: UUID
        
        /// Display filename for this injection (used in UI and mentions)
        var fileName: String
        
        /// Destination path inside the VM (e.g. ~/Documents/config.yaml)
        var guestPath: String

        /// Optional absolute path to the original host source file.
        /// When set, the latest file contents are copied on each VM startup.
        var sourceFilePath: String?

        /// Optional security-scoped bookmark for sourceFilePath.
        /// Used to retain read access across app launches.
        var sourceBookmarkData: Data?

        /// Returns the best available name for display and file staging.
        var resolvedFileName: String {
            if !fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return fileName
            }
            if let sourceFilePath, !sourceFilePath.isEmpty {
                return URL(fileURLWithPath: sourceFilePath).lastPathComponent
            }
            return "injected-file"
        }

        /// Indicates whether this injection is configured with a live host source reference.
        var hasLiveSourceReference: Bool {
            let hasPath = !(sourceFilePath?.isEmpty ?? true)
            return hasPath || sourceBookmarkData != nil
        }
        
        init(
            id: UUID = UUID(),
            fileName: String = "",
            guestPath: String = "",
            sourceFilePath: String? = nil,
            sourceBookmarkData: Data? = nil
        ) {
            self.id = id
            self.fileName = fileName
            self.guestPath = guestPath
            self.sourceFilePath = sourceFilePath
            self.sourceBookmarkData = sourceBookmarkData
        }
    }
}
