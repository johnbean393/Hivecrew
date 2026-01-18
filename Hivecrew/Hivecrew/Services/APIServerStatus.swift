//
//  APIServerStatus.swift
//  Hivecrew
//
//  Tracks the actual running state of the API server
//

import Foundation
import SwiftUI

/// Represents the current state of the API server
enum APIServerState: Equatable {
    case stopped
    case starting
    case running(port: Int)
    case failed(error: String)
    
    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
    
    var statusText: String {
        switch self {
        case .stopped:
            return "Stopped"
        case .starting:
            return "Starting..."
        case .running(let port):
            return "Running on port \(port)"
        case .failed(let error):
            return "Failed: \(error)"
        }
    }
    
    var statusColor: Color {
        switch self {
        case .stopped:
            return .secondary
        case .starting:
            return .orange
        case .running:
            return .green
        case .failed:
            return .red
        }
    }
}

/// Observable object that tracks the API server's actual running state
@MainActor
@Observable
final class APIServerStatus {
    
    /// Shared instance for app-wide access
    static let shared = APIServerStatus()
    
    /// Current server state
    var state: APIServerState = .stopped
    
    /// The port the server is actually running on (if running)
    var actualPort: Int? {
        if case .running(let port) = state {
            return port
        }
        return nil
    }
    
    private init() {}
    
    /// Called when the server starts successfully
    func serverStarted(port: Int) {
        state = .running(port: port)
    }
    
    /// Called when the server is starting
    func serverStarting() {
        state = .starting
    }
    
    /// Called when the server fails to start
    func serverFailed(error: String) {
        state = .failed(error: error)
    }
    
    /// Called when the server stops
    func serverStopped() {
        state = .stopped
    }
}
