//
//  TaskService+VMManagement.swift
//  Hivecrew
//
//  VM management, file operations, and helper methods
//

import Foundation
import SwiftData
import Virtualization
import Combine
import HivecrewLLM
import HivecrewShared
import UserNotifications

// MARK: - Ephemeral VM Management

extension TaskService {
    
    /// Get the default template ID from settings
    func getDefaultTemplateId() -> String? {
        UserDefaults.standard.string(forKey: "defaultTemplateId")
    }
    
    /// Generate a VM name based on task title and timestamp
    func generateVMName(for task: TaskRecord) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMdd-HHmmss"
        let timestamp = dateFormatter.string(from: Date())
        
        // Sanitize the title - remove special characters, limit length
        let sanitizedTitle = task.title
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined(separator: "-")
            .prefix(30)
        
        return "\(sanitizedTitle)-\(timestamp)"
    }
    
    /// Wait for a VM to be ready (started and accessible)
    func waitForVMReady(vmId: String) async throws -> VZVirtualMachine {
        let startTime = Date()
        let timeout: TimeInterval = 60 // 60 seconds to start
        
        while Date().timeIntervalSince(startTime) < timeout {
            if let vm = vmRuntime.getVM(id: vmId) {
                return vm
            }
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        }
        
        throw TaskServiceError.vmStartTimeout(vmId)
    }
    
    /// Delete an ephemeral VM after task completion
    /// Will NOT delete developer VMs or VMs associated with paused tasks
    func deleteEphemeralVM(vmId: String) async {
        // Safety check: don't delete protected VMs
        if isVMProtected(vmId) {
            print("TaskService: Skipping deletion of protected VM \(vmId) (developer or paused task)")
            return
        }
        
        print("TaskService: Deleting ephemeral VM \(vmId)...")

        do {
            // First stop the VM if it's still running
            if vmRuntime.getVM(id: vmId) != nil {
                try await vmRuntime.stopVM(id: vmId, force: true)
                // Wait for the VM to be fully released by the system
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            }

            // Then delete the VM files
            try await vmServiceClient.deleteVM(id: vmId)
            print("TaskService: Deleted ephemeral VM \(vmId)")
        } catch {
            print("TaskService: Failed to delete ephemeral VM \(vmId): \(error)")
            
            // If XPC service failed, try to delete the directory directly
            let vmPath = AppPaths.vmBundlePath(id: vmId)
            if FileManager.default.fileExists(atPath: vmPath.path) {
                do {
                    try FileManager.default.removeItem(at: vmPath)
                    print("TaskService: Deleted VM directory directly: \(vmId)")
                } catch {
                    print("TaskService: Failed to delete VM directory directly: \(error)")
                }
            }
        }
    }
    
    /// Connect to GuestAgent with retry (up to 3 minutes, retrying every 5 seconds)
    func connectToGuestAgent(vm: VZVirtualMachine, vmId: String) async throws -> GuestAgentConnection {
        let connection = GuestAgentConnection(vm: vm, vmId: vmId)
        
        let startTime = Date()
        var lastError: Error?
        var attemptCount = 0
        
        while Date().timeIntervalSince(startTime) < connectionTimeout {
            attemptCount += 1
            print("TaskService: Connection attempt \(attemptCount) to VM \(vmId)...")
            
            do {
                try await connection.connect()
                print("TaskService: Connected to GuestAgent on VM \(vmId) after \(attemptCount) attempt(s)")
                return connection
            } catch {
                lastError = error
                let elapsed = Int(Date().timeIntervalSince(startTime))
                let remaining = Int(connectionTimeout) - elapsed
                print("TaskService: Connection failed (\(error.localizedDescription)). Retrying in 5s... (\(remaining)s remaining)")
                
                // Wait before retrying
                try await Task.sleep(nanoseconds: connectionRetryInterval)
            }
        }
        
        print("TaskService: Connection to GuestAgent timed out after \(attemptCount) attempts")
        throw TaskServiceError.connectionTimeout(lastError?.localizedDescription ?? "Unknown error")
    }
    
    /// Create an LLM client from provider configuration
    func createLLMClient(
        providerId: String,
        modelId: String,
        reasoningEnabled: Bool? = nil,
        reasoningEffort: String? = nil,
        serviceTier: LLMServiceTier? = nil
    ) async throws -> any LLMClientProtocol {
        guard let context = modelContext else {
            throw TaskServiceError.noModelContext
        }
        
        // Fetch provider record
        let descriptor = FetchDescriptor<LLMProviderRecord>(predicate: #Predicate { $0.id == providerId })
        guard let provider = try context.fetch(descriptor).first else {
            throw TaskServiceError.providerNotFound(providerId)
        }

        // Codex providers require a completed ChatGPT login before run.
        if provider.backendMode == .codexOAuth && !provider.isOAuthAuthenticated {
            throw TaskServiceError.oauthAuthRequired(provider.displayName)
        }

        let apiKey: String
        if provider.authMode == .apiKey {
            guard let retrieved = provider.retrieveAPIKey() else {
                throw TaskServiceError.noAPIKey(provider.displayName)
            }
            apiKey = retrieved
        } else {
            apiKey = ""
        }

        let config = LLMConfiguration(
            id: provider.id,
            displayName: provider.displayName,
            baseURL: provider.backendMode == .codexOAuth ? nil : provider.parsedBaseURL,
            apiKey: apiKey,
            model: modelId,
            organizationId: provider.organizationId,
            backendMode: provider.backendMode,
            authMode: provider.authMode,
            timeoutInterval: LLMConfiguration.timeoutIntervalForReasoning(
                reasoningEnabled: reasoningEnabled,
                reasoningEffort: reasoningEffort
            ),
            reasoningEnabled: reasoningEnabled,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier
        )
        return LLMService.shared.createClient(from: config)
    }
    
    /// Create an LLM client for worker tasks.
    /// Worker model is required and powers lightweight/background LLM tasks.
    func createWorkerLLMClient(fallbackProviderId: String, fallbackModelId: String) async throws -> any LLMClientProtocol {
        _ = fallbackProviderId
        _ = fallbackModelId
        guard let workerProviderId = UserDefaults.standard.string(forKey: "workerModelProviderId"),
              let workerModelId = UserDefaults.standard.string(forKey: "workerModelId"),
              !workerProviderId.isEmpty,
              !workerModelId.isEmpty else {
            throw TaskServiceError.workerModelNotConfigured
        }

        guard let context = modelContext else {
            throw TaskServiceError.noModelContext
        }

        let descriptor = FetchDescriptor<LLMProviderRecord>(predicate: #Predicate { $0.id == workerProviderId })
        guard let provider = try context.fetch(descriptor).first else {
            throw TaskServiceError.providerNotFound(workerProviderId)
        }

        if provider.backendMode == .codexOAuth && !provider.isOAuthAuthenticated {
            throw TaskServiceError.oauthAuthRequired(provider.displayName)
        }

        let apiKey: String
        if provider.authMode == .apiKey {
            guard let retrieved = provider.retrieveAPIKey() else {
                throw TaskServiceError.noAPIKey(provider.displayName)
            }
            apiKey = retrieved
        } else {
            apiKey = ""
        }

        let config = LLMConfiguration(
            id: provider.id,
            displayName: provider.displayName,
            baseURL: provider.backendMode == .codexOAuth ? nil : provider.parsedBaseURL,
            apiKey: apiKey,
            model: workerModelId,
            organizationId: provider.organizationId,
            backendMode: provider.backendMode,
            authMode: provider.authMode,
            timeoutInterval: 300,
            reasoningEnabled: nil,
            reasoningEffort: nil,
            serviceTier: nil
        )
        return LLMService.shared.createClient(from: config)
    }
    
    /// Count running developer VMs (these count toward the concurrent VM limit)
    func countRunningDeveloperVMs() -> Int {
        // Get developer VM IDs from UserDefaults
        guard let data = UserDefaults.standard.data(forKey: "developerVMIds"),
              let developerVMIds = try? JSONDecoder().decode(Set<String>.self, from: data) else {
            return 0
        }
        
        // Count how many developer VMs are currently running in the app's VM runtime
        var count = 0
        for vmId in developerVMIds {
            if vmRuntime.getVM(id: vmId) != nil {
                count += 1
            }
        }
        
        return count
    }
}

// MARK: - File Operations

extension TaskService {
    
    /// Prepare the shared folder for a VM, copying input files to inbox
    /// - Returns: Array of file names that were copied to inbox
    func prepareSharedFolder(vmId: String, attachedFilePaths: [String]) throws -> [String] {
        let fm = FileManager.default
        
        // Create inbox, outbox, and workspace directories
        let inboxPath = AppPaths.vmInboxDirectory(id: vmId)
        let outboxPath = AppPaths.vmOutboxDirectory(id: vmId)
        let workspacePath = AppPaths.vmWorkspaceDirectory(id: vmId)
        
        try fm.createDirectory(at: inboxPath, withIntermediateDirectories: true)
        try fm.createDirectory(at: outboxPath, withIntermediateDirectories: true)
        try fm.createDirectory(at: workspacePath, withIntermediateDirectories: true)
        
        // Clear outbox from previous runs
        if let outboxContents = try? fm.contentsOfDirectory(at: outboxPath, includingPropertiesForKeys: nil) {
            for item in outboxContents {
                try? fm.removeItem(at: item)
            }
        }

        // Clear workspace so each task starts from a clean persisted snapshot.
        if let workspaceContents = try? fm.contentsOfDirectory(at: workspacePath, includingPropertiesForKeys: nil) {
            for item in workspaceContents {
                try? fm.removeItem(at: item)
            }
        }
        
        // Copy attached files to inbox
        var copiedFileNames: [String] = []
        for filePath in attachedFilePaths {
            let sourceURL = URL(fileURLWithPath: filePath)
            let fileName = sourceURL.lastPathComponent
            let destinationURL = inboxPath.appendingPathComponent(fileName)
            
            // Remove existing file with same name if present
            try? fm.removeItem(at: destinationURL)
            
            do {
                try fm.copyItem(at: sourceURL, to: destinationURL)
                copiedFileNames.append(fileName)
                print("TaskService: Copied '\(fileName)' to inbox")
            } catch {
                print("TaskService: Failed to copy '\(fileName)' to inbox: \(error)")
            }
        }
        
        return copiedFileNames
    }
    
    /// Copy files from VM's outbox to the configured output directory
    /// Files are saved into a subfolder named after the task title + timestamp
    /// - Parameters:
    ///   - vmId: The VM identifier
    ///   - taskTitle: The task title (used for subfolder naming)
    ///   - customOutputDirectory: Optional custom output directory path (overrides app settings)
    /// - Returns: Array of paths to copied files
    func copyOutboxFiles(vmId: String, taskTitle: String, customOutputDirectory: String? = nil) -> [String] {
        let fm = FileManager.default
        let outboxPath = AppPaths.vmOutboxDirectory(id: vmId)
        
        print("TaskService: copyOutboxFiles - outboxPath: \(outboxPath.path)")
        print("TaskService: copyOutboxFiles - outbox exists: \(fm.fileExists(atPath: outboxPath.path))")
        
        // Debug: List entire shared folder structure from host perspective
        let sharedPath = AppPaths.vmSharedDirectory(id: vmId)
        print("TaskService: Host shared folder contents:")
        if let enumerator = fm.enumerator(at: sharedPath, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]) {
            while let fileURL = enumerator.nextObject() as? URL {
                let relativePath = fileURL.path.replacingOccurrences(of: sharedPath.path, with: "")
                let attrs = try? fm.attributesOfItem(atPath: fileURL.path)
                let size = attrs?[.size] as? Int64 ?? 0
                let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                print("  \(relativePath) (\(isDir ? "dir" : "\(size) bytes"))")
            }
        }
        
        // Determine base output directory: custom > app setting > Downloads
        let baseOutputDirectory: URL
        if let customDir = customOutputDirectory, !customDir.isEmpty {
            // Use custom output directory from task/API request
            baseOutputDirectory = URL(fileURLWithPath: customDir)
        } else {
            // Fall back to app settings or Downloads
            let outputDirectoryPath = UserDefaults.standard.string(forKey: "outputDirectoryPath") ?? ""
            if outputDirectoryPath.isEmpty {
                // Default to Downloads
                baseOutputDirectory = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
            } else {
                baseOutputDirectory = URL(fileURLWithPath: outputDirectoryPath)
            }
        }
        
        // Create subfolder name from task title + timestamp
        let subfolderName = generateOutputSubfolderName(taskTitle: taskTitle)
        let outputDirectory = baseOutputDirectory.appendingPathComponent(subfolderName)
        
        print("TaskService: copyOutboxFiles - outputDirectory: \(outputDirectory.path)")
        
        // Ensure output directory exists
        try? fm.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        
        // Get files from outbox
        guard let outboxContents = try? fm.contentsOfDirectory(at: outboxPath, includingPropertiesForKeys: [.fileSizeKey]) else {
            print("TaskService: No outbox contents found or failed to list directory")
            // Try to list what's in the shared folder instead
            let sharedPath = AppPaths.vmSharedDirectory(id: vmId)
            if let sharedContents = try? fm.contentsOfDirectory(at: sharedPath, includingPropertiesForKeys: nil) {
                print("TaskService: Contents of shared folder: \(sharedContents.map { $0.lastPathComponent })")
            }
            return []
        }
        
        print("TaskService: copyOutboxFiles - found \(outboxContents.count) items in outbox")
        
        var copiedPaths: [String] = []
        
        for sourceURL in outboxContents {
            let fileName = sourceURL.lastPathComponent
            
            // Get file size for logging
            let fileSize = (try? fm.attributesOfItem(atPath: sourceURL.path)[.size] as? Int64) ?? 0
            print("TaskService: Processing outbox file '\(fileName)' (size: \(fileSize) bytes)")
            
            var destinationURL = outputDirectory.appendingPathComponent(fileName)
            
            // Handle filename conflicts by adding a number suffix
            var counter = 1
            let baseName = (fileName as NSString).deletingPathExtension
            let ext = (fileName as NSString).pathExtension
            
            while fm.fileExists(atPath: destinationURL.path) {
                let newName = ext.isEmpty ? "\(baseName) (\(counter))" : "\(baseName) (\(counter)).\(ext)"
                destinationURL = outputDirectory.appendingPathComponent(newName)
                counter += 1
            }
            
            do {
                try fm.copyItem(at: sourceURL, to: destinationURL)
                
                // Verify the copied file size
                let copiedSize = (try? fm.attributesOfItem(atPath: destinationURL.path)[.size] as? Int64) ?? 0
                print("TaskService: Copied '\(fileName)' to output directory (copied size: \(copiedSize) bytes)")
                
                copiedPaths.append(destinationURL.path)
            } catch {
                print("TaskService: Failed to copy '\(fileName)' from outbox: \(error)")
            }
        }
        
        return copiedPaths
    }

    /// Copy a VM workspace snapshot into the durable session artifacts directory.
    func persistWorkspaceSnapshot(vmId: String, sessionId: String) {
        let fm = FileManager.default
        let sourceDirectory = AppPaths.vmWorkspaceDirectory(id: vmId)
        let destinationDirectory = AppPaths.sessionWorkspaceDirectory(id: sessionId)

        guard fm.fileExists(atPath: sourceDirectory.path) else {
            return
        }

        do {
            if fm.fileExists(atPath: destinationDirectory.path) {
                try fm.removeItem(at: destinationDirectory)
            }
            try fm.copyItem(at: sourceDirectory, to: destinationDirectory)
            print("TaskService: Persisted workspace snapshot to \(destinationDirectory.path)")
        } catch {
            print("TaskService: Failed to persist workspace snapshot: \(error)")
        }
    }
    
    /// Generate a subfolder name for task output based on title and timestamp
    /// - Parameter taskTitle: The task title
    /// - Returns: Sanitized folder name in format "{title}-{timestamp}"
    private func generateOutputSubfolderName(taskTitle: String) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = dateFormatter.string(from: Date())
        
        // Sanitize the title - remove special characters, limit length
        let sanitizedTitle = taskTitle
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .prefix(50)
        
        // Handle empty title case
        let titlePart = sanitizedTitle.isEmpty ? "task" : String(sanitizedTitle)
        
        return "\(titlePart)-\(timestamp)"
    }
}
