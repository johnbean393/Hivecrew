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
        var config = APIConfiguration.load()
        config.apiKey = APIKeyManager.retrieveAPIKey()
        
        guard config.isEnabled else {
            print("APIServerManager: API server is disabled")
            APIServerStatus.shared.serverStopped()
            return
        }
        
        startServer(with: config)
    }
    
    /// Stop the API server
    func stop() {
        serverTask?.cancel()
        serverTask = nil
        currentServer = nil
        APIServerStatus.shared.serverStopped()
        print("APIServerManager: Server stopped")
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
        guard let taskService = taskService, let modelContext = modelContext else {
            print("APIServerManager: Not configured - call configure() first")
            APIServerStatus.shared.serverFailed(error: "Server not configured")
            return
        }
        
        // Update status to starting
        APIServerStatus.shared.serverStarting()
        
        // Create file storage
        let fileStorage = TaskFileStorage()
        
        // Create service provider
        let serviceProvider = APIServiceProviderBridge(
            taskService: taskService,
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
            } catch {
                if !Task.isCancelled {
                    print("APIServerManager: Failed to start server: \(error)")
                    await MainActor.run {
                        let errorMessage = parseServerError(error)
                        APIServerStatus.shared.serverFailed(error: errorMessage)
                    }
                }
            }
        }
        
        // Mark as running after a brief delay
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            await MainActor.run {
                // Only mark as running if still in starting state
                if case .starting = APIServerStatus.shared.state {
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
