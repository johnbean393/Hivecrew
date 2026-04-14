//
//  APIProvisioning.swift
//  HivecrewAPI
//
//  VM provisioning models for API responses (environment variables and injected files)
//

import Foundation

/// An environment variable configured for VM provisioning
public struct APIEnvironmentVariable: Codable, Sendable {
    /// The variable name/key
    public let key: String
    
    public init(key: String) {
        self.key = key
    }
}

/// A file configured for injection into VMs
public struct APIInjectedFile: Codable, Sendable {
    /// The filename as stored in the assets directory
    public let fileName: String
    /// The destination path inside the VM
    public let guestPath: String
    
    public init(fileName: String, guestPath: String) {
        self.fileName = fileName
        self.guestPath = guestPath
    }
}

/// Response for GET /provisioning
public struct APIProvisioningResponse: Codable, Sendable {
    public let environmentVariables: [APIEnvironmentVariable]
    public let injectedFiles: [APIInjectedFile]
    
    public init(
        environmentVariables: [APIEnvironmentVariable],
        injectedFiles: [APIInjectedFile]
    ) {
        self.environmentVariables = environmentVariables
        self.injectedFiles = injectedFiles
    }
}
