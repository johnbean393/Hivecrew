//
//  AgentDaemon.swift
//  HivecrewGuestAgent
//
//  Created by Hivecrew on 1/11/26.
//

import Foundation
import ApplicationServices
import ScreenCaptureKit
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
    
    /// Start the daemon and begin listening for connections
    func run() {
        isRunning = true
        
        // Trigger permission prompts on startup
        triggerPermissionPrompts()
        
        // Try to mount shared folder
        mountSharedFolder()
        
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
                // Print synchronously so we can see the error
                let errorMsg = "Failed to start vsock server (attempt \(retryCount)/\(maxRetries)): \(error)"
                print(errorMsg)
                fputs("\(errorMsg)\n", stderr)
                fflush(stderr)
                
                if retryCount < maxRetries {
                    // Wait 1 second before retrying
                    Thread.sleep(forTimeInterval: 1.0)
                }
            }
        }
        
        if !serverStarted {
            let msg = "Vsock server failed to start after \(maxRetries) attempts. Exiting."
            print(msg)
            fputs("\(msg)\n", stderr)
            fflush(stderr)
            exit(1)
        }
        
        // Run the main loop
        logger.log("Agent daemon running. Waiting for connections...")
        
        while isRunning {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 1.0))
        }
        
        logger.log("Agent daemon stopped")
    }
    
    /// Gracefully shutdown the daemon
    func shutdown() {
        logger.log("Shutdown requested...")
        isRunning = false
        server?.stop()
    }
    
    // MARK: - Startup Tasks
    
    /// Trigger permission prompts by attempting to use protected APIs
    /// Accessibility is requested first since Screen Recording may require app restart
    private func triggerPermissionPrompts() {
        logger.log("Triggering permission prompts...")
        
        // 1. FIRST: Trigger Accessibility permission prompt
        // Use AXIsProcessTrustedWithOptions with kAXTrustedCheckOptionPrompt to show the dialog
        logger.log("Requesting Accessibility permission...")
        // The key string is "AXTrustedCheckOptionPrompt" - use literal to avoid concurrency issues
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let accessibilityGranted = AXIsProcessTrustedWithOptions(options)
        logger.log("Accessibility permission: \(accessibilityGranted ? "granted" : "not granted (dialog shown)")")
        
        // Give user time to respond to Accessibility prompt before Screen Recording
        if !accessibilityGranted {
            logger.log("Waiting for user to respond to Accessibility prompt...")
            Thread.sleep(forTimeInterval: 2.0)
        }
        
        // 2. SECOND: Trigger Screen Recording permission prompt
        // Attempting to get shareable content will trigger the prompt
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
        // Note: This may require root, so we try with a helper script approach
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", """
            # Create mount point if needed
            if [ ! -d "\(sharedPath)" ]; then
                sudo mkdir -p "\(sharedPath)" 2>/dev/null || mkdir -p "\(sharedPath)" 2>/dev/null
            fi
            
            # Try to mount (may fail without sudo)
            mount_virtiofs shared "\(sharedPath)" 2>/dev/null || \
            sudo mount_virtiofs shared "\(sharedPath)" 2>/dev/null || \
            echo "Mount failed - may need manual setup"
            """]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
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
