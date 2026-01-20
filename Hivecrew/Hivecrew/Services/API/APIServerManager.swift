//
//  APIServerManager.swift
//  Hivecrew
//
//  Manages the lifecycle of the API server, including starting, stopping, and restarting
//

import Foundation
import SwiftData
import HivecrewAPI

/// Manages the API server lifecycle
@MainActor
final class APIServerManager {
    
    /// Shared instance
    static let shared = APIServerManager()
    
    /// Current running task for the API server
    private var serverTask: Task<Void, Never>?
    
    /// Current server instance
    private var currentServer: HivecrewAPIServer?
    
    /// Whether the server was successfully started (passed initial startup)
    private var serverSuccessfullyStarted = false
    
    /// The port the server was started on
    private var startedPort: Int?
    
    /// Dependencies needed to create the server
    private var taskService: TaskService?
    private var modelContext: ModelContext?
    
    private init() {}
    
    /// Configure the manager with required dependencies
    func configure(taskService: TaskService, modelContext: ModelContext) {
        self.taskService = taskService
        self.modelContext = modelContext
    }
    
    /// Start the API server if enabled
    func startIfEnabled() {
        // Don't start if already running
        if serverSuccessfullyStarted {
            print("APIServerManager: startIfEnabled called but server already running - ignoring")
            return
        }
        
        var config = APIConfiguration.load()
        config.apiKey = APIKeyManager.retrieveAPIKey()
        
        guard config.isEnabled else {
            print("APIServerManager: API server is disabled")
            APIServerStatus.shared.serverStopped()
            return
        }
        
        print("APIServerManager: startIfEnabled - starting server on port \(config.port)")
        startServer(with: config)
    }
    
    /// Stop the API server
    func stop() {
        serverTask?.cancel()
        serverTask = nil
        currentServer = nil
        serverSuccessfullyStarted = false
        startedPort = nil
        APIServerStatus.shared.serverStopped()
        print("APIServerManager: Server stopped")
    }
    
    /// Refresh the status display based on actual server state
    /// Call this when the Settings view appears to sync the UI
    func refreshStatus() {
        if serverSuccessfullyStarted, let port = startedPort {
            // Server was successfully started and should still be running
            APIServerStatus.shared.serverStarted(port: port)
        } else if serverTask != nil, !serverTask!.isCancelled {
            // Server task is actively running (starting up)
            // Only set to starting if not already in a failed state
            if case .failed = APIServerStatus.shared.state {
                // Keep the failed state - don't overwrite it
            } else {
                APIServerStatus.shared.serverStarting()
            }
        } else if !UserDefaults.standard.bool(forKey: "apiServerEnabled") {
            // Server is disabled
            APIServerStatus.shared.serverStopped()
        }
        // If enabled but not running and not starting, keep current state (could be failed)
    }
    
    /// Restart the server with current configuration
    func restart() {
        stop()
        
        // Brief delay before restarting
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            await MainActor.run {
                startIfEnabled()
            }
        }
    }
    
    /// Start the server with the given configuration
    private func startServer(with config: APIConfiguration) {
        // Don't start if already running
        if serverSuccessfullyStarted {
            print("APIServerManager: Server already running, skipping start")
            return
        }
        
        // Cancel any existing server task before starting a new one
        if serverTask != nil {
            print("APIServerManager: Cancelling existing server task")
            serverTask?.cancel()
            serverTask = nil
        }
        
        guard let taskService = taskService, let modelContext = modelContext else {
            print("APIServerManager: Not configured - call configure() first")
            APIServerStatus.shared.serverFailed(error: "Server not configured")
            return
        }
        
        // Reset startup flags
        serverSuccessfullyStarted = false
        startedPort = nil
        
        // Update status to starting
        APIServerStatus.shared.serverStarting()
        
        // Create file storage
        let fileStorage = TaskFileStorage()
        
        // Create service provider
        let serviceProvider = APIServiceProviderBridge(
            taskService: taskService,
            schedulerService: SchedulerService.shared,
            vmServiceClient: VMServiceClient.shared,
            modelContext: modelContext,
            fileStorage: fileStorage
        )
        
        // Create the server
        let server = HivecrewAPIServer(
            configuration: config,
            serviceProvider: serviceProvider,
            fileStorage: fileStorage
        )
        
        self.currentServer = server
        let port = config.port
        
        serverTask = Task {
            do {
                // Brief delay to allow error detection
                try await Task.sleep(for: .milliseconds(100))
                
                // Start the server (this will throw if port is in use)
                try await server.start()
                
                // If start() returns normally, the server has shut down gracefully
                if !Task.isCancelled {
                    print("APIServerManager: Server shut down gracefully")
                    await MainActor.run {
                        self.serverTask = nil
                        self.currentServer = nil
                        self.serverSuccessfullyStarted = false
                        self.startedPort = nil
                        APIServerStatus.shared.serverStopped()
                    }
                }
            } catch {
                if !Task.isCancelled {
                    let errorString = String(describing: error)
                    print("APIServerManager: Server error: \(error)")
                    
                    // Check if this is a startup error (port in use) vs runtime error
                    let isStartupError = errorString.contains("bind") || 
                                         errorString.contains("address already in use") ||
                                         errorString.contains("EADDRINUSE")
                    
                    await MainActor.run {
                        if !self.serverSuccessfullyStarted {
                            // Failed during startup - report the error
                            self.serverTask = nil
                            self.currentServer = nil
                            let errorMessage = self.parseServerError(error)
                            APIServerStatus.shared.serverFailed(error: errorMessage)
                        } else if isStartupError {
                            // This shouldn't happen if server was running - ignore
                            // (might be a duplicate start attempt)
                            print("APIServerManager: Ignoring startup error for already-running server")
                        } else {
                            // Runtime error - server has stopped
                            self.serverTask = nil
                            self.currentServer = nil
                            self.serverSuccessfullyStarted = false
                            self.startedPort = nil
                            APIServerStatus.shared.serverStopped()
                        }
                    }
                }
            }
        }
        
        // Mark as running after a brief delay (if no error occurred)
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            await MainActor.run {
                // Only mark as running if still in starting state (no error occurred)
                if case .starting = APIServerStatus.shared.state {
                    self.serverSuccessfullyStarted = true
                    self.startedPort = port
                    APIServerStatus.shared.serverStarted(port: port)
                }
            }
        }
        
        print("APIServerManager: Server starting on port \(port)")
    }
    
    /// Parse server error to get a user-friendly message
    private func parseServerError(_ error: Error) -> String {
        let errorString = String(describing: error)
        if errorString.contains("address already in use") || errorString.contains("EADDRINUSE") {
            return "Port already in use"
        }
        if errorString.contains("permission denied") {
            return "Permission denied"
        }
        return error.localizedDescription
    }
}
