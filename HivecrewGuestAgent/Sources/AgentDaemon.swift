//
//  AgentDaemon.swift
//  HivecrewGuestAgent
//
//  Created by Hivecrew on 1/11/26.
//

import Foundation
import AppKit
import ApplicationServices
import ScreenCaptureKit
import Photos
import Contacts
import EventKit
import CoreLocation
import AVFoundation
import HivecrewAgentProtocol

/// The main daemon class that manages the agent lifecycle
final class AgentDaemon: @unchecked Sendable {
    nonisolated(unsafe) static var shared: AgentDaemon?
    
    private let logger = AgentLogger.shared
    private var server: VsockServer?
    private var isRunning = false
    private let toolHandler = ToolHandler()
    
    init() {
        AgentDaemon.shared = self
        logger.log("HivecrewGuestAgent v\(AgentProtocol.agentVersion) starting...")
    }
    
    /// Start the daemon and begin listening for connections.
    /// This method is called from a background queue. The main thread runs
    /// NSApplication's event loop to stay responsive to macOS system events.
    func start() {
        isRunning = true
        
        // IMPORTANT: Start the vsock server FIRST so the host can connect immediately.
        // Permission prompts and shared folder mounting happen afterward.
        
        // Try to start vsock server with retries
        var serverStarted = false
        var retryCount = 0
        let maxRetries = 60  // Retry for up to 60 seconds
        
        while isRunning && !serverStarted && retryCount < maxRetries {
            server = VsockServer(port: AgentProtocol.vsockPort, handler: toolHandler)
            
            do {
                try server?.start()
                logger.log("Vsock server started on port \(AgentProtocol.vsockPort)")
                serverStarted = true
            } catch {
                retryCount += 1
                let errorMsg = "Failed to start vsock server (attempt \(retryCount)/\(maxRetries)): \(error)"
                print(errorMsg)
                fputs("\(errorMsg)\n", stderr)
                fflush(stderr)
                
                if retryCount < maxRetries {
                    Thread.sleep(forTimeInterval: 1.0)
                }
            }
        }
        
        if !serverStarted {
            let msg = "Vsock server failed to start after \(maxRetries) attempts. Exiting."
            print(msg)
            fputs("\(msg)\n", stderr)
            fflush(stderr)
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
            return
        }
        
        logger.log("Agent daemon running. Waiting for connections...")
        
        // Now that the server is running, perform setup tasks in the background
        // so they don't block the agent from responding to host requests.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            
            // Trigger permission prompts (non-critical for basic operation)
            self.triggerPermissionPrompts()
            
            // Try to mount shared folder (with timeout protection)
            self.mountSharedFolder()
        }
    }
    
    /// Gracefully shutdown the daemon
    func shutdown() {
        logger.log("Shutdown requested...")
        isRunning = false
        server?.stop()
        
        // Terminate NSApplication to exit the process
        DispatchQueue.main.async {
            NSApplication.shared.terminate(nil)
        }
    }
    
    // MARK: - Startup Tasks
    
    /// Trigger permission prompts by attempting to use protected APIs.
    /// Accessibility is requested first since Screen Recording may require app restart.
    ///
    /// NOTE: NSApplication must be running on the main thread for permission
    /// dialogs to display. This is handled by main.swift.
    private func triggerPermissionPrompts() {
        logger.log("Triggering permission prompts...")
        
        // 1. Trigger Accessibility permission prompt
        logger.log("Requesting Accessibility permission...")
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let accessibilityGranted = AXIsProcessTrustedWithOptions(options)
        logger.log("Accessibility permission: \(accessibilityGranted ? "granted" : "not granted (dialog shown)")")
        
        // Brief pause before Screen Recording prompt so they don't overlap
        if !accessibilityGranted {
            logger.log("Accessibility not yet granted, continuing with other permission requests...")
            Thread.sleep(forTimeInterval: 0.5)
        }
        
        // 2. Trigger Screen Recording permission prompt
        logger.log("Requesting Screen Recording permission...")
        Task {
            do {
                let content = try await SCShareableContent.current
                if content.displays.isEmpty {
                    self.logger.log("Screen Recording: no displays (permission denied or pending)")
                } else {
                    self.logger.log("Screen Recording permission: granted (\(content.displays.count) displays)")
                }
            } catch {
                self.logger.log("Screen Recording permission request triggered: \(error)")
            }
        }
        
        // 3. Trigger file access permissions for user folders
        triggerFileAccessPermissions()
        
        // 4. Trigger app/data access permissions
        triggerPhotosAccessPermission()
        triggerContactsAccessPermission()
        triggerCalendarAccessPermission()
        triggerRemindersAccessPermission()
        triggerFullDiskAccessCheck()
        triggerAutomationPermission()
        triggerCameraAndMicrophonePermissions()
        triggerLocationPermission()
        
        // 5. Trigger broader data access permissions (other apps, media, etc.)
        triggerBroaderDataAccessPermissions()
    }
    
    /// Trigger file access permission prompts for protected user folders.
    /// This allows the user to grant permissions on startup rather than during task execution.
    private func triggerFileAccessPermissions() {
        logger.log("Requesting file access permissions for user folders...")
        
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        
        // TCC-protected user folders that trigger permission prompts
        let protectedFolders = [
            "Desktop",
            "Documents",
            "Downloads"
        ]
        
        for folderName in protectedFolders {
            let folderPath = (homeDirectory as NSString).appendingPathComponent(folderName)
            
            do {
                let contents = try FileManager.default.contentsOfDirectory(atPath: folderPath)
                logger.log("\(folderName) folder access: granted (\(contents.count) items)")
            } catch let error as NSError {
                if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError {
                    logger.log("\(folderName) folder access: permission dialog shown or denied")
                } else if error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
                    logger.log("\(folderName) folder: does not exist")
                } else {
                    logger.log("\(folderName) folder access: \(error.localizedDescription)")
                }
            }
        }
    }
    
    /// Trigger broader data access permissions to ensure the agent can access
    /// data from other apps, media libraries, and protected system locations.
    private func triggerBroaderDataAccessPermissions() {
        logger.log("Triggering broader data access permissions...")
        
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        
        // Access additional user directories that may trigger "access data from other apps" prompts.
        // On macOS 15+, accessing files created by other apps can trigger a system prompt.
        let additionalFolders: [(String, String)] = [
            ("Music", "Music folder"),
            ("Pictures", "Pictures folder"),
            ("Movies", "Movies folder"),
            ("Library/Application Support", "Application Support (other apps' data)"),
        ]
        
        for (relativePath, description) in additionalFolders {
            let fullPath = (homeDirectory as NSString).appendingPathComponent(relativePath)
            do {
                let contents = try FileManager.default.contentsOfDirectory(atPath: fullPath)
                logger.log("\(description): accessible (\(contents.count) items)")
            } catch let error as NSError {
                if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError {
                    logger.log("\(description): permission dialog shown or denied")
                } else if error.code == NSFileNoSuchFileError {
                    logger.log("\(description): directory doesn't exist")
                } else {
                    logger.log("\(description): \(error.localizedDescription)")
                }
            }
        }
        
        // Access the system Applications directory to trigger any app data prompts
        do {
            let apps = try FileManager.default.contentsOfDirectory(atPath: "/Applications")
            logger.log("Applications directory: accessible (\(apps.count) apps)")
        } catch {
            logger.log("Applications directory: \(error.localizedDescription)")
        }
        
        // Try to access removable volumes and network volumes (triggers prompts if connected)
        let volumesPath = "/Volumes"
        if FileManager.default.fileExists(atPath: volumesPath) {
            do {
                let volumes = try FileManager.default.contentsOfDirectory(atPath: volumesPath)
                logger.log("Volumes: accessible (\(volumes.count) volumes)")
                
                // Try reading contents of each volume to trigger removable/network volume prompts
                for volume in volumes where volume != "Macintosh HD" {
                    let volumePath = (volumesPath as NSString).appendingPathComponent(volume)
                    _ = try? FileManager.default.contentsOfDirectory(atPath: volumePath)
                }
            } catch {
                logger.log("Volumes: \(error.localizedDescription)")
            }
        }
    }
    
    /// Trigger Photos library access permission
    private func triggerPhotosAccessPermission() {
        logger.log("Requesting Photos library access...")
        
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        
        switch status {
        case .authorized, .limited:
            logger.log("Photos access: already authorized")
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
                switch newStatus {
                case .authorized:
                    self.logger.log("Photos access: authorized")
                case .limited:
                    self.logger.log("Photos access: limited access granted")
                case .denied, .restricted:
                    self.logger.log("Photos access: denied or restricted")
                case .notDetermined:
                    self.logger.log("Photos access: still not determined")
                @unknown default:
                    self.logger.log("Photos access: unknown status")
                }
            }
        case .denied, .restricted:
            logger.log("Photos access: previously denied or restricted")
        @unknown default:
            logger.log("Photos access: unknown status")
        }
    }
    
    /// Trigger Contacts access permission
    private func triggerContactsAccessPermission() {
        logger.log("Requesting Contacts access...")
        
        let store = CNContactStore()
        let status = CNContactStore.authorizationStatus(for: .contacts)
        
        switch status {
        case .authorized:
            logger.log("Contacts access: already authorized")
        case .notDetermined:
            store.requestAccess(for: .contacts) { granted, error in
                if granted {
                    self.logger.log("Contacts access: authorized")
                } else if let error = error {
                    self.logger.log("Contacts access: denied - \(error.localizedDescription)")
                } else {
                    self.logger.log("Contacts access: denied")
                }
            }
        case .denied, .restricted:
            logger.log("Contacts access: previously denied or restricted")
        case .limited:
            logger.log("Contacts access: limited access granted")
        @unknown default:
            logger.log("Contacts access: unknown status")
        }
    }
    
    /// Trigger Calendar access permission
    private func triggerCalendarAccessPermission() {
        logger.log("Requesting Calendar access...")
        
        let eventStore = EKEventStore()
        
        if #available(macOS 14.0, *) {
            let status = EKEventStore.authorizationStatus(for: .event)
            
            switch status {
            case .authorized, .fullAccess, .writeOnly:
                logger.log("Calendar access: already authorized")
            case .notDetermined:
                eventStore.requestFullAccessToEvents { granted, error in
                    if granted {
                        self.logger.log("Calendar access: authorized")
                    } else if let error = error {
                        self.logger.log("Calendar access: denied - \(error.localizedDescription)")
                    } else {
                        self.logger.log("Calendar access: denied")
                    }
                }
            case .denied, .restricted:
                logger.log("Calendar access: previously denied or restricted")
            @unknown default:
                logger.log("Calendar access: unknown status")
            }
        } else {
            eventStore.requestAccess(to: .event) { granted, error in
                if granted {
                    self.logger.log("Calendar access: authorized")
                } else if let error = error {
                    self.logger.log("Calendar access: denied - \(error.localizedDescription)")
                } else {
                    self.logger.log("Calendar access: denied")
                }
            }
        }
    }
    
    /// Trigger Reminders access permission
    private func triggerRemindersAccessPermission() {
        logger.log("Requesting Reminders access...")
        
        let eventStore = EKEventStore()
        
        if #available(macOS 14.0, *) {
            let status = EKEventStore.authorizationStatus(for: .reminder)
            
            switch status {
            case .authorized, .fullAccess, .writeOnly:
                logger.log("Reminders access: already authorized")
            case .notDetermined:
                eventStore.requestFullAccessToReminders { granted, error in
                    if granted {
                        self.logger.log("Reminders access: authorized")
                    } else if let error = error {
                        self.logger.log("Reminders access: denied - \(error.localizedDescription)")
                    } else {
                        self.logger.log("Reminders access: denied")
                    }
                }
            case .denied, .restricted:
                logger.log("Reminders access: previously denied or restricted")
            @unknown default:
                logger.log("Reminders access: unknown status")
            }
        } else {
            eventStore.requestAccess(to: .reminder) { granted, error in
                if granted {
                    self.logger.log("Reminders access: authorized")
                } else if let error = error {
                    self.logger.log("Reminders access: denied - \(error.localizedDescription)")
                } else {
                    self.logger.log("Reminders access: denied")
                }
            }
        }
    }
    
    /// Check for Full Disk Access by testing protected directories
    private func triggerFullDiskAccessCheck() {
        logger.log("Checking Full Disk Access...")
        
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        
        let protectedDirectories = [
            ("Library/Mail", "Mail data"),
            ("Library/Messages", "Messages data"),
            ("Library/Safari", "Safari data"),
            ("Library/Cookies", "Cookies"),
            ("Library/Application Support/MobileSync", "iOS backups")
        ]
        
        var hasFullDiskAccess = true
        
        for (relativePath, description) in protectedDirectories {
            let fullPath = (homeDirectory as NSString).appendingPathComponent(relativePath)
            
            do {
                _ = try FileManager.default.contentsOfDirectory(atPath: fullPath)
                logger.log("Full Disk Access (\(description)): accessible")
            } catch let error as NSError {
                if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError {
                    hasFullDiskAccess = false
                    logger.log("Full Disk Access (\(description)): not accessible - permission denied")
                } else if error.code == NSFileNoSuchFileError {
                    logger.log("Full Disk Access (\(description)): directory doesn't exist")
                } else {
                    logger.log("Full Disk Access (\(description)): \(error.localizedDescription)")
                }
            }
        }
        
        if !hasFullDiskAccess {
            logger.log("Full Disk Access: Not fully granted. Some protected directories are inaccessible.")
            logger.log("To grant Full Disk Access: System Settings > Privacy & Security > Full Disk Access")
        } else {
            logger.log("Full Disk Access: All tested directories accessible")
        }
    }
    
    /// Trigger Automation permission by attempting to control System Events
    private func triggerAutomationPermission() {
        logger.log("Checking Automation permissions...")
        
        let script = """
        tell application "System Events"
            return name of first process whose frontmost is true
        end tell
        """
        
        DispatchQueue.global(qos: .utility).async {
            if let appleScript = NSAppleScript(source: script) {
                var error: NSDictionary?
                let result = appleScript.executeAndReturnError(&error)
                
                if let error = error {
                    let errorNumber = error[NSAppleScript.errorNumber] as? Int ?? 0
                    if errorNumber == -1743 {
                        self.logger.log("Automation (System Events): permission prompt shown or denied")
                    } else {
                        self.logger.log("Automation (System Events): error \(errorNumber)")
                    }
                } else {
                    self.logger.log("Automation (System Events): authorized - \(result.stringValue ?? "success")")
                }
            } else {
                self.logger.log("Automation: failed to create AppleScript")
            }
        }
        
        let finderScript = """
        tell application "Finder"
            return name of desktop
        end tell
        """
        
        DispatchQueue.global(qos: .utility).async {
            if let appleScript = NSAppleScript(source: finderScript) {
                var error: NSDictionary?
                let result = appleScript.executeAndReturnError(&error)
                
                if let error = error {
                    let errorNumber = error[NSAppleScript.errorNumber] as? Int ?? 0
                    if errorNumber == -1743 {
                        self.logger.log("Automation (Finder): permission prompt shown or denied")
                    } else {
                        self.logger.log("Automation (Finder): error \(errorNumber)")
                    }
                } else {
                    self.logger.log("Automation (Finder): authorized - \(result.stringValue ?? "success")")
                }
            }
        }
    }
    
    /// Trigger Camera and Microphone access permissions
    private func triggerCameraAndMicrophonePermissions() {
        logger.log("Requesting Camera and Microphone access...")
        
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        switch cameraStatus {
        case .authorized:
            logger.log("Camera access: already authorized")
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted {
                    self.logger.log("Camera access: authorized")
                } else {
                    self.logger.log("Camera access: denied")
                }
            }
        case .denied, .restricted:
            logger.log("Camera access: previously denied or restricted")
        @unknown default:
            logger.log("Camera access: unknown status")
        }
        
        let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        switch microphoneStatus {
        case .authorized:
            logger.log("Microphone access: already authorized")
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                if granted {
                    self.logger.log("Microphone access: authorized")
                } else {
                    self.logger.log("Microphone access: denied")
                }
            }
        case .denied, .restricted:
            logger.log("Microphone access: previously denied or restricted")
        @unknown default:
            logger.log("Microphone access: unknown status")
        }
    }
    
    /// Trigger Location Services permission
    private func triggerLocationPermission() {
        logger.log("Checking Location Services access...")
        
        let status = CLLocationManager.authorizationStatus()
        
        switch status {
        case .authorizedAlways:
            logger.log("Location access: authorized always")
        case .authorized:
            logger.log("Location access: authorized")
        case .notDetermined:
            logger.log("Location access: not determined (requires user action in System Settings)")
            logger.log("To enable Location Services: System Settings > Privacy & Security > Location Services")
        case .denied:
            logger.log("Location access: denied")
        case .restricted:
            logger.log("Location access: restricted")
        @unknown default:
            logger.log("Location access: unknown status")
        }
        
        if !CLLocationManager.locationServicesEnabled() {
            logger.log("Location Services: disabled system-wide")
        }
    }
    
    /// Try to mount the shared folder if not already mounted
    private func mountSharedFolder() {
        let sharedPath = "/Volumes/Shared"
        
        // Check if already mounted
        if FileManager.default.fileExists(atPath: sharedPath) {
            let contents = try? FileManager.default.contentsOfDirectory(atPath: sharedPath)
            if let contents = contents, !contents.isEmpty {
                logger.log("Shared folder already mounted at \(sharedPath)")
                return
            }
        }
        
        logger.log("Attempting to mount shared folder...")
        
        // Try to mount VirtioFS
        // Avoid sudo to prevent hanging when no TTY is available
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", """
            # Create mount point if needed
            if [ ! -d "\(sharedPath)" ]; then
                mkdir -p "\(sharedPath)" 2>/dev/null
            fi
            
            # Try to mount (without sudo to avoid password prompt hangs)
            mount_virtiofs shared "\(sharedPath)" 2>/dev/null || \
            echo "Mount failed - may need manual setup"
            """]
        
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // Prevent the process from inheriting stdin (avoids sudo/password hangs)
        process.standardInput = FileHandle.nullDevice
        
        let mountTimeout: TimeInterval = 10  // seconds
        
        do {
            try process.run()
            
            // Wait with a timeout to prevent indefinite hangs
            let deadline = Date(timeIntervalSinceNow: mountTimeout)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.25)
            }
            
            if process.isRunning {
                logger.warning("Mount process timed out after \(Int(mountTimeout))s - terminating")
                process.terminate()
                Thread.sleep(forTimeInterval: 1.0)
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                return
            }
            
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                logger.log("Mount output: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            
            // Check if mount succeeded
            if FileManager.default.fileExists(atPath: sharedPath) {
                let contents = try? FileManager.default.contentsOfDirectory(atPath: sharedPath)
                if let contents = contents, !contents.isEmpty {
                    logger.log("Shared folder mounted successfully")
                } else {
                    logger.log("Shared folder mount point exists but appears empty")
                }
            }
        } catch {
            logger.log("Failed to run mount command: \(error)")
        }
    }
}
