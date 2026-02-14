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
    case missingLLMClient
    case workerModelNotConfigured
    
    var errorDescription: String? {
        switch self {
        case .noModelContext:
            return String(localized: "Model context not set")
        case .noTemplateConfigured:
            return String(localized: "No default template configured. Please set a template in Settings → Environment.")
        case .vmCreationFailed(let reason):
            return String(localized: "Failed to create VM: \(reason)")
        case .vmStartTimeout(let name):
            return String(localized: "Timed out waiting for VM '\(name)' to start")
        case .connectionTimeout(let details):
            return String(localized: "Connection to GuestAgent timed out: \(details)")
        case .providerNotFound(let id):
            return String(localized: "LLM provider not found: \(id)")
        case .noAPIKey(let provider):
            return String(localized: "No API key configured for \(provider)")
        case .missingLLMClient:
            return String(localized: "LLM client was unavailable during task startup")
        case .workerModelNotConfigured:
            return String(localized: "Worker model is required. Configure it in onboarding or Settings → Providers.")
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
