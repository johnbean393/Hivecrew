//
//  VMError.swift
//  HivecrewShared
//
//  Created by Hivecrew on 1/10/26.
//

import Foundation

/// Errors that can occur during VM operations
public enum VMError: Error, Codable, Sendable {
    case vmNotFound(id: String)
    case vmAlreadyRunning(id: String)
    case vmNotRunning(id: String)
    case installationFailed(reason: String)
    case configurationInvalid(reason: String)
    case diskCreationFailed(reason: String)
    case insufficientResources(reason: String)
    case internalError(reason: String)
    
    public var localizedDescription: String {
        switch self {
        case .vmNotFound(let id):
            return "Virtual machine not found: \(id)"
        case .vmAlreadyRunning(let id):
            return "Virtual machine is already running: \(id)"
        case .vmNotRunning(let id):
            return "Virtual machine is not running: \(id)"
        case .installationFailed(let reason):
            return "Installation failed: \(reason)"
        case .configurationInvalid(let reason):
            return "Invalid configuration: \(reason)"
        case .diskCreationFailed(let reason):
            return "Disk creation failed: \(reason)"
        case .insufficientResources(let reason):
            return "Insufficient resources: \(reason)"
        case .internalError(let reason):
            return "Internal error: \(reason)"
        }
    }
}

/// Wrapper for XPC-compatible error transport
public struct VMErrorWrapper: Codable, Sendable {
    public let error: VMError
    
    public init(_ error: VMError) {
        self.error = error
    }
    
    public func toDictionary() -> [String: Any] {
        guard let data = try? JSONEncoder().encode(self),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["error": "encoding_failed"]
        }
        return dict
    }
    
    public static func fromDictionary(_ dict: [String: Any]) -> VMErrorWrapper? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let wrapper = try? JSONDecoder().decode(VMErrorWrapper.self, from: data) else {
            return nil
        }
        return wrapper
    }
}
