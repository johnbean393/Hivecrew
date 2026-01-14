//
//  TaskService+VMCleanup.swift
//  Hivecrew
//
//  VM cleanup logic for orphaned and ephemeral VMs
//

import Foundation
import SwiftData
import HivecrewShared

// MARK: - VM Cleanup

extension TaskService {
    
    /// Clean up orphaned VM directories on startup
    /// This removes VMs that:
    /// - Are NOT developer VMs
    /// - Are NOT associated with paused tasks (which should persist)
    /// - Are NOT associated with active tasks (queued, waitingForVM, running)
    func cleanupOrphanedVMs() async {
        let fm = FileManager.default
        let vmDir = AppPaths.vmDirectory
        
        print("TaskService: Scanning for orphaned VMs in \(vmDir.path)...")
        
        // Get all VM directories
        guard let vmContents = try? fm.contentsOfDirectory(at: vmDir, includingPropertiesForKeys: [.isDirectoryKey]) else {
            print("TaskService: Could not read VM directory")
            return
        }
        
        // Get developer VM IDs
        let developerVMIds = getDeveloperVMIds()
        
        // Get VM IDs that should be preserved (paused or active tasks)
        let preservedVMIds = getPreservedVMIds()
        
        var deletedCount = 0
        var skippedCount = 0
        
        for vmPath in vmContents {
            // Check if it's a directory
            guard let isDirectory = try? vmPath.resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
                  isDirectory == true else {
                continue
            }
            
            let vmId = vmPath.lastPathComponent
            
            // Skip developer VMs
            if developerVMIds.contains(vmId) {
                print("TaskService: Skipping developer VM: \(vmId)")
                skippedCount += 1
                continue
            }
            
            // Skip VMs that should be preserved (paused or active tasks)
            if preservedVMIds.contains(vmId) {
                print("TaskService: Skipping preserved VM (paused/active task): \(vmId)")
                skippedCount += 1
                continue
            }
            
            // This VM is orphaned - delete it
            print("TaskService: Deleting orphaned VM: \(vmId)")
            do {
                try fm.removeItem(at: vmPath)
                deletedCount += 1
            } catch {
                print("TaskService: Failed to delete orphaned VM \(vmId): \(error)")
            }
        }
        
        print("TaskService: VM cleanup complete. Deleted: \(deletedCount), Skipped: \(skippedCount)")
    }
    
    /// Get the set of developer VM IDs from UserDefaults
    private func getDeveloperVMIds() -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: "developerVMIds"),
              let ids = try? JSONDecoder().decode(Set<String>.self, from: data) else {
            return []
        }
        return ids
    }
    
    /// Get VM IDs that should be preserved (paused or active tasks)
    private func getPreservedVMIds() -> Set<String> {
        var preserved = Set<String>()
        
        for task in tasks {
            // Preserve VMs for paused tasks (so they can be resumed)
            // Also preserve VMs for active tasks (queued, waitingForVM, running)
            if task.status == .paused || task.status.isActive {
                if let vmId = task.assignedVMId {
                    preserved.insert(vmId)
                }
            }
        }
        
        return preserved
    }
    
    /// Check if a VM is protected (developer VM or associated with a paused/active task)
    func isVMProtected(_ vmId: String) -> Bool {
        // Check if it's a developer VM
        let developerVMIds = getDeveloperVMIds()
        if developerVMIds.contains(vmId) {
            return true
        }
        
        // Check if it's associated with a paused or active task
        for task in tasks {
            if task.assignedVMId == vmId {
                if task.status == .paused || task.status.isActive {
                    return true
                }
            }
        }
        
        return false
    }
    
    /// Check if a VM directory exists for a given VM ID
    func vmDirectoryExists(_ vmId: String) -> Bool {
        let vmPath = AppPaths.vmBundlePath(id: vmId)
        return FileManager.default.fileExists(atPath: vmPath.path)
    }
}
