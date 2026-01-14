//
//  GuestAgentTypes.swift
//  Hivecrew
//
//  Types, models, and errors for GuestAgentConnection
//

import Foundation

// MARK: - Result Types

struct ScreenshotResult: Sendable {
    let imageBase64: String
    let width: Int
    let height: Int
}

struct ShellResult: Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

struct HealthCheckResult: Sendable {
    let status: String
    let accessibilityPermission: Bool
    let screenRecordingPermission: Bool
    let sharedFolderMounted: Bool
    let sharedFolderPath: String?
    let agentVersion: String
}

struct FrontmostAppResult: Sendable {
    let bundleId: String?
    let appName: String?
    let windowTitle: String?
}

struct AccessibilityElementResult: Sendable {
    let role: String
    let text: String?
    let x: Double?
    let y: Double?
    let width: Double?
    let height: Double?
}

struct AccessibilityTraversalResult: Sendable {
    let appName: String
    let elements: [AccessibilityElementResult]
    let processingTimeSeconds: String
}

/// Result of reading a file - either text content or image data
enum FileReadResult: Sendable {
    /// Text-based file content (plain text, PDF, docx, etc.)
    case text(content: String, fileType: String)
    
    /// Image file with base64-encoded PNG data
    case image(base64: String, mimeType: String, width: Int?, height: Int?)
    
    /// Get a text description of the result (for logging/display)
    var description: String {
        switch self {
        case .text(let content, let fileType):
            return "[\(fileType.uppercased())] \(content.prefix(100))..."
        case .image(_, let mimeType, let width, let height):
            var desc = "Image (\(mimeType))"
            if let w = width, let h = height {
                desc += " \(w)x\(h)"
            }
            return desc
        }
    }
}

// MARK: - AgentRequest/Response (copied from protocol package for host use)

struct AgentRequest: Codable {
    let jsonrpc: String
    let id: String
    let method: String
    let params: [String: AnyCodable]?
    
    init(id: String, method: String, params: [String: AnyCodable]? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }
}

struct AgentResponse: Codable {
    let jsonrpc: String
    let id: String
    let result: AnyCodable?
    let error: AgentErrorResponse?
}

struct AgentErrorResponse: Codable {
    let code: Int
    let message: String
}

// MARK: - AnyCodable

struct AnyCodable: Codable {
    let value: Any
    
    init(_ value: Any) {
        self.value = value
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if container.decodeNil() {
            self.value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            self.value = bool
        } else if let int = try? container.decode(Int.self) {
            self.value = int
        } else if let double = try? container.decode(Double.self) {
            self.value = double
        } else if let string = try? container.decode(String.self) {
            self.value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            self.value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            self.value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode AnyCodable")
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            let context = EncodingError.Context(codingPath: container.codingPath, debugDescription: "Cannot encode AnyCodable")
            throw EncodingError.invalidValue(value, context)
        }
    }
    
    var dictValue: [String: Any]? { value as? [String: Any] }
    var stringValue: String? { value as? String }
    var intValue: Int? { value as? Int }
    var boolValue: Bool? { value as? Bool }
}

// MARK: - Errors

enum AgentConnectionError: Error, LocalizedError {
    case noSocketDevice
    case connectionFailed
    case notConnected
    case disconnected
    case timeout
    case invalidResponse
    case agentError(code: Int, message: String)
    
    var errorDescription: String? {
        switch self {
        case .noSocketDevice:
            return "VM does not have a vsock device"
        case .connectionFailed:
            return "Failed to connect to GuestAgent"
        case .notConnected:
            return "Not connected to GuestAgent"
        case .disconnected:
            return "Disconnected from GuestAgent"
        case .timeout:
            return "Request timed out"
        case .invalidResponse:
            return "Invalid response from GuestAgent"
        case .agentError(_, let message):
            return message
        }
    }
}

// MARK: - Timeout Helper

/// Execute an async operation with a timeout
func withTimeout<T>(seconds: Double, operation: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw AgentConnectionError.timeout
        }
        
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
