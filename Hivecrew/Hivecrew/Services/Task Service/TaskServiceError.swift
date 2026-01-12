//
//  TaskServiceError.swift
//  Hivecrew
//
//  Error types and AppPaths extension for TaskService
//

import Foundation
import HivecrewShared

// MARK: - Errors

enum TaskServiceError: Error, LocalizedError {
    case noModelContext
    case noTemplateConfigured
    case vmCreationFailed(String)
    case vmStartTimeout(String)
    case connectionTimeout(String)
    case providerNotFound(String)
    case noAPIKey(String)
    
    var errorDescription: String? {
        switch self {
        case .noModelContext:
            return "Model context not set"
        case .noTemplateConfigured:
            return "No default template configured. Please set a template in Settings → Environment."
        case .vmCreationFailed(let reason):
            return "Failed to create VM: \(reason)"
        case .vmStartTimeout(let name):
            return "Timed out waiting for VM '\(name)' to start"
        case .connectionTimeout(let details):
            return "Connection to GuestAgent timed out: \(details)"
        case .providerNotFound(let id):
            return "LLM provider not found: \(id)"
        case .noAPIKey(let provider):
            return "No API key configured for \(provider)"
        }
    }
}

// MARK: - App Paths Extension

extension AppPaths {
    static func sessionPath(id: String) -> URL {
        let sessionsDir = applicationSupportDirectory.appendingPathComponent("Sessions")
        return sessionsDir.appendingPathComponent(id)
    }
    
    static var applicationSupportDirectory: URL {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        return paths[0].appendingPathComponent("Hivecrew")
    }
}
