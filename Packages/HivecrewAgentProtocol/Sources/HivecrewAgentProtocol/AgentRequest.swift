//
//  AgentRequest.swift
//  HivecrewAgentProtocol
//
//  Created by Hivecrew on 1/11/26.
//

import Foundation

/// JSON-RPC 2.0 Request
public struct AgentRequest: Codable, Sendable {
    public let jsonrpc: String
    public let id: String
    public let method: String
    public let params: [String: AnyCodable]?
    
    public init(id: String = UUID().uuidString, method: String, params: [String: AnyCodable]? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }
    
    /// Create a request with typed parameters
    public static func create<T: Encodable>(method: String, params: T) throws -> AgentRequest {
        let encoder = JSONEncoder()
        let data = try encoder.encode(params)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let anyCodableDict = dict.mapValues { AnyCodable($0) }
        return AgentRequest(method: method, params: anyCodableDict)
    }
}

/// JSON-RPC 2.0 Response
public struct AgentResponse: Codable, Sendable {
    public let jsonrpc: String
    public let id: String
    public let result: AnyCodable?
    public let error: AgentError?
    
    public init(id: String, result: AnyCodable? = nil, error: AgentError? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = error
    }
    
    /// Create a success response
    public static func success(id: String, result: Any) -> AgentResponse {
        return AgentResponse(id: id, result: AnyCodable(result))
    }
    
    /// Create an error response
    public static func failure(id: String, code: Int, message: String, data: Any? = nil) -> AgentResponse {
        let error = AgentError(code: code, message: message, data: data.map { AnyCodable($0) })
        return AgentResponse(id: id, error: error)
    }
}

/// JSON-RPC 2.0 Error
public struct AgentError: Codable, Sendable, Error {
    public let code: Int
    public let message: String
    public let data: AnyCodable?
    
    public init(code: Int, message: String, data: AnyCodable? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
    
    // Standard JSON-RPC error codes
    public static let parseError = -32700
    public static let invalidRequest = -32600
    public static let methodNotFound = -32601
    public static let invalidParams = -32602
    public static let internalError = -32603
    
    // Custom error codes (application-specific)
    public static let permissionDenied = -1001
    public static let toolExecutionFailed = -1002
    public static let notConnected = -1003
}

/// A type-erased Codable value for JSON-RPC params/results
/// Uses @unchecked Sendable because the contained value is immutable after initialization
public struct AnyCodable: Codable, @unchecked Sendable {
    public let value: Any
    
    public init(_ value: Any) {
        self.value = value
    }
    
    public init(from decoder: Decoder) throws {
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
    
    public func encode(to encoder: Encoder) throws {
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
    
    // Helper accessors
    public var stringValue: String? { value as? String }
    public var intValue: Int? { value as? Int }
    public var doubleValue: Double? { value as? Double }
    public var boolValue: Bool? { value as? Bool }
    public var arrayValue: [Any]? { value as? [Any] }
    public var dictValue: [String: Any]? { value as? [String: Any] }
}
