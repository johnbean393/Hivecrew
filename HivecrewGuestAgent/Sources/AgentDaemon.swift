//
//  AgentDaemon.swift
//  HivecrewGuestAgent
//
//  Created by Hivecrew on 1/11/26.
//

import Foundation
import AppKit
import HivecrewAgentProtocol

/// The main daemon class that manages the agent lifecycle
final class AgentDaemon: @unchecked Sendable {
    nonisolated(unsafe) static var shared: AgentDaemon?
    
    let logger = AgentLogger.shared
    var server: VsockServer?
    var isRunning = false
    let toolHandler = ToolHandler()
    
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
    
}
