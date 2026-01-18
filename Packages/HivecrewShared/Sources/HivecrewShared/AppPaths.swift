//
//  AppPaths.swift
//  HivecrewShared
//
//  Created by Bean John on 1/10/26.
//

import Foundation

/// Centralized file paths for the Hivecrew application
public enum AppPaths {
    
    // MARK: - Base Directories
    
    /// The real (non-sandboxed) home directory
    private static let realHomeDirectory: URL = {
        // Get the real home directory from the passwd database
        // This bypasses sandbox container remapping
        if let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: home), isDirectory: true)
        }
        // Fallback to environment variable
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            // Check if it's a container path and extract real home
            if home.contains("/Library/Containers/") {
                // Extract: /Users/username/Library/Containers/... -> /Users/username
                let components = home.components(separatedBy: "/Library/Containers/")
                if let realHome = components.first, !realHome.isEmpty {
                    return URL(fileURLWithPath: realHome, isDirectory: true)
                }
            }
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }()
    
    /// Base application support directory for Hivecrew
    /// Uses the non-sandboxed path directly to avoid container isolation issues
    public static let appSupportDirectory: URL = {
        let url = realHomeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Hivecrew", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    
    // MARK: - VM Storage
    
    /// Directory containing all VM bundles
    public static let vmDirectory: URL = {
        let url = appSupportDirectory.appendingPathComponent("VMs", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    
    /// Returns the bundle path for a specific VM
    public static func vmBundlePath(id: String) -> URL {
        vmDirectory.appendingPathComponent(id, isDirectory: true)
    }
    
    /// Returns the config file path for a specific VM
    public static func vmConfigPath(id: String) -> URL {
        vmBundlePath(id: id).appendingPathComponent("config.json")
    }
    
    /// Returns the disk image path for a specific VM
    public static func vmDiskPath(id: String) -> URL {
        vmBundlePath(id: id).appendingPathComponent("disk.img")
    }
    
    /// Returns the auxiliary storage path for a specific VM
    public static func vmAuxiliaryPath(id: String) -> URL {
        vmBundlePath(id: id).appendingPathComponent("auxiliary")
    }
    
    /// Returns the machine identifier path for a specific VM
    public static func vmMachineIdentifierPath(id: String) -> URL {
        vmBundlePath(id: id).appendingPathComponent("MachineIdentifier.bin")
    }
    
    /// Returns the shared folder path for a specific VM
    public static func vmSharedDirectory(id: String) -> URL {
        vmBundlePath(id: id).appendingPathComponent("shared", isDirectory: true)
    }
    
    /// Returns the inbox folder path for a specific VM (input files for agent)
    public static func vmInboxDirectory(id: String) -> URL {
        vmSharedDirectory(id: id).appendingPathComponent("inbox", isDirectory: true)
    }
    
    /// Returns the outbox folder path for a specific VM (output files from agent)
    public static func vmOutboxDirectory(id: String) -> URL {
        vmSharedDirectory(id: id).appendingPathComponent("outbox", isDirectory: true)
    }
    
    /// Returns the workspace folder path for a specific VM (scratch space)
    public static func vmWorkspaceDirectory(id: String) -> URL {
        vmSharedDirectory(id: id).appendingPathComponent("workspace", isDirectory: true)
    }
    
    // MARK: - Session Storage
    
    /// Directory containing session traces and artifacts
    public static let sessionsDirectory: URL = {
        let url = appSupportDirectory.appendingPathComponent("Sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    
    /// Returns the directory for a specific session
    public static func sessionDirectory(id: String) -> URL {
        sessionsDirectory.appendingPathComponent(id, isDirectory: true)
    }
    
    /// Returns the trace file path for a specific session
    public static func sessionTracePath(id: String) -> URL {
        sessionDirectory(id: id).appendingPathComponent("trace.json")
    }
    
    /// Returns the screenshots directory for a specific session
    public static func sessionScreenshotsDirectory(id: String) -> URL {
        sessionDirectory(id: id).appendingPathComponent("screenshots", isDirectory: true)
    }
    
    // MARK: - Templates Storage
    
    /// Directory containing VM templates (golden images)
    public static let templatesDirectory: URL = {
        let url = appSupportDirectory.appendingPathComponent("Templates", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    
    /// Returns the bundle path for a specific template
    public static func templateBundlePath(id: String) -> URL {
        templatesDirectory.appendingPathComponent(id, isDirectory: true)
    }
    
    /// Returns the config file path for a specific template
    public static func templateConfigPath(id: String) -> URL {
        templateBundlePath(id: id).appendingPathComponent("config.json")
    }
    
    /// Returns the disk image path for a specific template
    public static func templateDiskPath(id: String) -> URL {
        templateBundlePath(id: id).appendingPathComponent("disk.img")
    }
    
    /// Returns the auxiliary storage path for a specific template
    public static func templateAuxiliaryPath(id: String) -> URL {
        templateBundlePath(id: id).appendingPathComponent("auxiliary")
    }
    
    /// Returns the hardware model path for a specific template
    public static func templateHardwareModelPath(id: String) -> URL {
        templateBundlePath(id: id).appendingPathComponent("HardwareModel.bin")
    }
    
    // MARK: - Logs
    
    /// Directory for application logs
    public static let logsDirectory: URL = {
        let url = appSupportDirectory.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    
    // MARK: - Display Paths
    
    /// Human-readable path for VM storage (for display in UI)
    public static var vmDirectoryDisplayPath: String {
        vmDirectory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
    
    /// Human-readable path for session storage (for display in UI)
    public static var sessionsDirectoryDisplayPath: String {
        sessionsDirectory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}
