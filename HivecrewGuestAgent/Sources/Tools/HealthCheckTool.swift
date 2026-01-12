//
//  HealthCheckTool.swift
//  HivecrewGuestAgent
//
//  Created by Hivecrew on 1/11/26.
//

import Foundation
import ApplicationServices
import ScreenCaptureKit
import HivecrewAgentProtocol

/// Tool for checking agent health and permissions
final class HealthCheckTool: @unchecked Sendable {
    private let logger = AgentLogger.shared
    
    /// Execute a health check and return status information
    func execute() throws -> [String: Any] {
        logger.log("Performing health check...")
        
        let accessibilityPermission = checkAccessibilityPermission()
        let screenRecordingPermission = checkScreenRecordingPermissionSync()
        let sharedFolderMounted = checkSharedFolderMounted()
        
        var status = "healthy"
        if !accessibilityPermission || !screenRecordingPermission {
            status = "degraded"
        }
        if !sharedFolderMounted {
            status = "warning"
        }
        
        var result: [String: Any] = [
            "status": status,
            "accessibilityPermission": accessibilityPermission,
            "screenRecordingPermission": screenRecordingPermission,
            "sharedFolderMounted": sharedFolderMounted,
            "agentVersion": AgentProtocol.agentVersion
        ]
        
        if sharedFolderMounted {
            result["sharedFolderPath"] = AgentProtocol.sharedFolderMountPath
        }
        
        logger.log("Health check complete: \(status)")
        
        return result
    }
    
    /// Check if the app has accessibility permissions
    private func checkAccessibilityPermission() -> Bool {
        // AXIsProcessTrusted returns true if the app is trusted for accessibility
        return AXIsProcessTrusted()
    }
    
    /// Check if the app has screen recording permissions (synchronous wrapper)
    private func checkScreenRecordingPermissionSync() -> Bool {
        // Use a simple check - try to access SCShareableContent
        // This is a best-effort check
        let semaphore = DispatchSemaphore(value: 0)
        
        // Use a class to safely share state across threads
        final class ResultBox: @unchecked Sendable {
            var hasPermission = false
        }
        let box = ResultBox()
        
        DispatchQueue.global(qos: .userInitiated).async {
            Task {
                do {
                    let content = try await SCShareableContent.current
                    box.hasPermission = !content.displays.isEmpty
                } catch {
                    box.hasPermission = false
                }
                semaphore.signal()
            }
        }
        
        // Wait with timeout
        _ = semaphore.wait(timeout: .now() + 2.0)
        
        return box.hasPermission
    }
    
    /// Check if the shared folder is mounted
    private func checkSharedFolderMounted() -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: AgentProtocol.sharedFolderMountPath, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
