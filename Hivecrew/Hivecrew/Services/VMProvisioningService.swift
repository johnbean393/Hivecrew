//
//  VMProvisioningService.swift
//  Hivecrew
//
//  Manages loading/saving VM provisioning configuration and asset files
//

import Combine
import Foundation
import HivecrewShared

/// Manages the global VM provisioning configuration and file injection sources
class VMProvisioningService: ObservableObject {
    
    static let shared = VMProvisioningService()
    
    /// The current provisioning configuration
    @Published var config: VMProvisioningConfig
    
    private let fileManager = FileManager.default
    
    private init() {
        self.config = Self.loadConfig()
    }
    
    // MARK: - Configuration Persistence
    
    /// Load configuration from disk
    private static func loadConfig() -> VMProvisioningConfig {
        let path = AppPaths.vmProvisioningConfigPath
        guard FileManager.default.fileExists(atPath: path.path) else {
            return .empty
        }
        
        do {
            let data = try Data(contentsOf: path)
            let config = try JSONDecoder().decode(VMProvisioningConfig.self, from: data)
            return config
        } catch {
            print("VMProvisioningService: Failed to load config: \(error)")
            return .empty
        }
    }
    
    /// Save the current configuration to disk
    func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: AppPaths.vmProvisioningConfigPath, options: .atomic)
            print("VMProvisioningService: Config saved")
        } catch {
            print("VMProvisioningService: Failed to save config: \(error)")
        }
    }
    
    /// Reload configuration from disk
    func reload() {
        config = Self.loadConfig()
    }
    
    // MARK: - Environment Variable Helpers
    
    /// Generate a shell export string for all defined environment variables
    /// Returns something like: export FOO="bar"; export BAZ="qux"
    var environmentExportString: String {
        environmentExportLines.joined(separator: "; ")
    }
    
    /// Generate individual export lines for all defined environment variables
    /// Each line is like: export FOO="bar"
    var environmentExportLines: [String] {
        let validVars = config.environmentVariables.filter { !$0.key.isEmpty }
        guard !validVars.isEmpty else { return [] }
        
        return validVars.map { envVar in
            // Escape double quotes and backslashes in values for safe shell injection
            let escapedValue = envVar.value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "export \(envVar.key)=\"\(escapedValue)\""
        }
    }
    
    /// Generate the contents of a zshenv file that exports all user-defined environment variables
    /// Returns nil if there are no variables to export
    var zshenvContents: String? {
        let lines = environmentExportLines
        guard !lines.isEmpty else { return nil }
        
        var content = "# Hivecrew VM provisioning — environment variables\n"
        content += "# This file is auto-generated on VM startup. Do not edit.\n"
        content += lines.joined(separator: "\n")
        content += "\n"
        return content
    }
    
    // MARK: - File Management

    /// Create a file injection that references the original host file directly.
    /// The returned injection stores both the file path and (when possible) a
    /// security-scoped bookmark so updates to the source file are picked up on each VM startup.
    func createFileInjection(from sourceURL: URL) throws -> VMProvisioningConfig.FileInjection {
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let fileName = sourceURL.lastPathComponent
        let bookmarkData = try? sourceURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        return VMProvisioningConfig.FileInjection(
            fileName: fileName,
            guestPath: "~/Desktop/\(fileName)",
            sourceFilePath: sourceURL.path,
            sourceBookmarkData: bookmarkData
        )
    }
    
    /// Import a file from a source URL into the Assets/VM/ directory
    /// - Parameter sourceURL: The file to import (may be a security-scoped URL)
    /// - Returns: The file name as stored in the assets directory
    @discardableResult
    func importFile(from sourceURL: URL) throws -> String {
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        
        let fileName = sourceURL.lastPathComponent
        let destinationURL = AppPaths.vmAssetsDirectory.appendingPathComponent(fileName)
        
        // Remove existing file with same name
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        print("VMProvisioningService: Imported file '\(fileName)' to assets directory")
        
        return fileName
    }
    
    /// Remove a file from the Assets/VM/ directory
    func removeFile(named fileName: String) {
        guard !fileName.isEmpty else { return }
        let fileURL = AppPaths.vmAssetsDirectory.appendingPathComponent(fileName)
        
        do {
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
                print("VMProvisioningService: Removed asset file '\(fileName)'")
            }
        } catch {
            print("VMProvisioningService: Failed to remove asset file '\(fileName)': \(error)")
        }
    }
    
    /// Check if an asset file exists
    func assetFileExists(named fileName: String) -> Bool {
        let fileURL = AppPaths.vmAssetsDirectory.appendingPathComponent(fileName)
        return fileManager.fileExists(atPath: fileURL.path)
    }

    /// Resolve the configured source URL for a file injection (bookmark first, then raw path).
    func sourceFileURL(for injection: VMProvisioningConfig.FileInjection) -> URL? {
        if let bookmarkData = injection.sourceBookmarkData {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return url
            }
        }

        if let sourceFilePath = injection.sourceFilePath, !sourceFilePath.isEmpty {
            return URL(fileURLWithPath: sourceFilePath)
        }

        return nil
    }

    /// Resolve the best host file URL to use for an injection.
    /// Prefers live source references and falls back to legacy assets for backward compatibility.
    func hostFileURL(for injection: VMProvisioningConfig.FileInjection) -> URL? {
        if let sourceURL = sourceFileURL(for: injection) {
            return sourceURL
        }

        let legacyAssetURL = AppPaths.vmAssetsDirectory.appendingPathComponent(injection.resolvedFileName)
        if fileManager.fileExists(atPath: legacyAssetURL.path) {
            return legacyAssetURL
        }

        return nil
    }

    /// Whether the injection currently resolves to an existing host file.
    func fileInjectionSourceExists(_ injection: VMProvisioningConfig.FileInjection) -> Bool {
        guard let sourceURL = hostFileURL(for: injection) else { return false }
        return fileManager.fileExists(atPath: sourceURL.path)
    }
    
    // MARK: - VM Provisioning
    
    /// Copy all provisioned files into a VM's shared inbox directory.
    /// Files are placed in a `_provisioning/` subdirectory to avoid conflicts with task attachments.
    /// - Parameter inboxURL: The VM's shared inbox directory URL
    /// - Returns: Array of (stagedFileName, guestPath) tuples for files that were successfully copied
    func copyProvisionedFiles(toSharedInbox inboxURL: URL) -> [(fileName: String, guestPath: String)] {
        let validInjections = config.fileInjections.filter { !$0.guestPath.isEmpty }
        guard !validInjections.isEmpty else { return [] }
        
        // Create provisioning subdirectory in inbox
        let provisioningDir = inboxURL.appendingPathComponent("_provisioning", isDirectory: true)
        try? fileManager.createDirectory(at: provisioningDir, withIntermediateDirectories: true)
        
        var copiedFiles: [(fileName: String, guestPath: String)] = []
        
        for injection in validInjections {
            guard let sourceURL = hostFileURL(for: injection) else {
                print("VMProvisioningService: No source found for injection '\(injection.resolvedFileName)', skipping")
                continue
            }

            guard fileManager.fileExists(atPath: sourceURL.path) else {
                print("VMProvisioningService: Source file '\(sourceURL.path)' not found, skipping")
                continue
            }

            let safeBaseName = injection.resolvedFileName.replacingOccurrences(of: "/", with: "_")
            let stagedFileName = "\(injection.id.uuidString)-\(safeBaseName)"
            let destURL = provisioningDir.appendingPathComponent(stagedFileName)

            let accessing = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            do {
                // Remove existing copy if present
                if fileManager.fileExists(atPath: destURL.path) {
                    try fileManager.removeItem(at: destURL)
                }

                try fileManager.copyItem(at: sourceURL, to: destURL)
                copiedFiles.append((fileName: stagedFileName, guestPath: injection.guestPath))
                print("VMProvisioningService: Copied '\(sourceURL.lastPathComponent)' to shared inbox for injection to '\(injection.guestPath)'")
            } catch {
                print("VMProvisioningService: Failed to copy '\(sourceURL.lastPathComponent)': \(error)")
            }
        }
        
        return copiedFiles
    }
    
    /// Generate a shell script to move provisioned files from the shared inbox to their guest paths
    /// - Parameter copiedFiles: Array of (fileName, guestPath) from copyProvisionedFiles
    /// - Returns: A shell command string that moves all files to their destinations
    func generateFileInjectionScript(for copiedFiles: [(fileName: String, guestPath: String)]) -> String {
        guard !copiedFiles.isEmpty else { return "" }
        
        let vmHomePath = "/Users/hivecrew"
        
        var commands: [String] = []
        for (fileName, guestPath) in copiedFiles {
            // Expand ~ to the actual home path
            let expandedPath = guestPath
                .replacingOccurrences(of: "~/", with: "\(vmHomePath)/")
                .replacingOccurrences(of: "$HOME/", with: "\(vmHomePath)/")
                .replacingOccurrences(of: "${HOME}/", with: "\(vmHomePath)/")
            
            // Ensure parent directory exists, then copy
            let parentDir = (expandedPath as NSString).deletingLastPathComponent
            commands.append("mkdir -p \"\(parentDir)\" && cp -f \"/Volumes/Shared/inbox/_provisioning/\(fileName)\" \"\(expandedPath)\"")
        }
        
        return commands.joined(separator: " && ")
    }
}
