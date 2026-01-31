//
//  HealthCheckTool.swift
//  HivecrewGuestAgent
//
//  Created by Hivecrew on 1/11/26.
//

import Foundation
import ApplicationServices
import ScreenCaptureKit
import Photos
import Contacts
import EventKit
import AVFoundation
import CoreLocation
import HivecrewAgentProtocol

/// Tool for checking agent health and permissions
final class HealthCheckTool: @unchecked Sendable {
    private let logger = AgentLogger.shared
    
    /// Execute a health check and return status information
    func execute() throws -> [String: Any] {
        logger.log("Performing health check...")
        
        // Core permissions (required for basic functionality)
        let accessibilityPermission = checkAccessibilityPermission()
        let screenRecordingPermission = checkScreenRecordingPermissionSync()
        let sharedFolderMounted = checkSharedFolderMounted()
        
        // Extended permissions (for additional capabilities)
        let photosPermission = checkPhotosPermission()
        let contactsPermission = checkContactsPermission()
        let calendarPermission = checkCalendarPermission()
        let remindersPermission = checkRemindersPermission()
        let fullDiskAccess = checkFullDiskAccess()
        let automationPermission = checkAutomationPermissionSync()
        let cameraPermission = checkCameraPermission()
        let microphonePermission = checkMicrophonePermission()
        let locationPermission = checkLocationPermission()
        
        // Determine overall status
        var status = "healthy"
        if !accessibilityPermission || !screenRecordingPermission {
            status = "degraded"
        }
        if !sharedFolderMounted {
            status = "warning"
        }
        
        // Build permissions summary
        let permissions: [String: Any] = [
            // Core permissions
            "accessibility": accessibilityPermission,
            "screenRecording": screenRecordingPermission,
            
            // File/Data access
            "fullDiskAccess": fullDiskAccess,
            
            // App data access
            "photos": photosPermission,
            "contacts": contactsPermission,
            "calendar": calendarPermission,
            "reminders": remindersPermission,
            
            // Automation
            "automation": automationPermission,
            
            // Hardware
            "camera": cameraPermission,
            "microphone": microphonePermission,
            "location": locationPermission
        ]
        
        var result: [String: Any] = [
            "status": status,
            "permissions": permissions,
            // Keep legacy fields for backward compatibility
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
    
    // MARK: - Core Permission Checks
    
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
    
    // MARK: - App Data Permission Checks
    
    /// Check Photos library access status
    private func checkPhotosPermission() -> String {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized:
            return "authorized"
        case .limited:
            return "limited"
        case .notDetermined:
            return "notDetermined"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        @unknown default:
            return "unknown"
        }
    }
    
    /// Check Contacts access status
    private func checkContactsPermission() -> String {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized:
            return "authorized"
        case .notDetermined:
            return "notDetermined"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        case .limited:
            return "limited"
        @unknown default:
            return "unknown"
        }
    }
    
    /// Check Calendar access status
    private func checkCalendarPermission() -> String {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .authorized:
            return "authorized"
        case .fullAccess:
            return "fullAccess"
        case .writeOnly:
            return "writeOnly"
        case .notDetermined:
            return "notDetermined"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        @unknown default:
            return "unknown"
        }
    }
    
    /// Check Reminders access status
    private func checkRemindersPermission() -> String {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        switch status {
        case .authorized:
            return "authorized"
        case .fullAccess:
            return "fullAccess"
        case .writeOnly:
            return "writeOnly"
        case .notDetermined:
            return "notDetermined"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        @unknown default:
            return "unknown"
        }
    }
    
    // MARK: - Full Disk Access Check
    
    /// Check Full Disk Access by testing access to protected directories
    private func checkFullDiskAccess() -> Bool {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        
        // Test directories that require Full Disk Access
        let testPaths = [
            "Library/Mail",
            "Library/Messages",
            "Library/Safari"
        ]
        
        for relativePath in testPaths {
            let fullPath = (homeDirectory as NSString).appendingPathComponent(relativePath)
            
            // Check if directory exists first
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDirectory) && isDirectory.boolValue {
                // Try to access it
                do {
                    _ = try FileManager.default.contentsOfDirectory(atPath: fullPath)
                    // If we can access it, we have Full Disk Access
                } catch let error as NSError {
                    if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError {
                        return false
                    }
                }
            }
        }
        
        return true
    }
    
    // MARK: - Automation Permission Check
    
    /// Check Automation permission by testing AppleScript execution (synchronous wrapper)
    private func checkAutomationPermissionSync() -> Bool {
        let script = """
        tell application "System Events"
            return name of first process whose frontmost is true
        end tell
        """
        
        guard let appleScript = NSAppleScript(source: script) else {
            return false
        }
        
        var error: NSDictionary?
        _ = appleScript.executeAndReturnError(&error)
        
        if let error = error {
            let errorNumber = error[NSAppleScript.errorNumber] as? Int ?? 0
            // Error -1743 is "not authorized to send Apple events"
            return errorNumber != -1743
        }
        
        return true
    }
    
    // MARK: - Hardware Permission Checks
    
    /// Check Camera access status
    private func checkCameraPermission() -> String {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            return "authorized"
        case .notDetermined:
            return "notDetermined"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        @unknown default:
            return "unknown"
        }
    }
    
    /// Check Microphone access status
    private func checkMicrophonePermission() -> String {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return "authorized"
        case .notDetermined:
            return "notDetermined"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        @unknown default:
            return "unknown"
        }
    }
    
    // MARK: - Location Permission Check
    
    /// Check Location Services access status
    private func checkLocationPermission() -> [String: Any] {
        let status = CLLocationManager.authorizationStatus()
        let servicesEnabled = CLLocationManager.locationServicesEnabled()
        
        var statusString: String
        switch status {
        case .authorizedAlways:
            statusString = "authorizedAlways"
        case .authorized:
            statusString = "authorized"
        case .notDetermined:
            statusString = "notDetermined"
        case .denied:
            statusString = "denied"
        case .restricted:
            statusString = "restricted"
        @unknown default:
            statusString = "unknown"
        }
        
        return [
            "status": statusString,
            "servicesEnabled": servicesEnabled
        ]
    }
}
