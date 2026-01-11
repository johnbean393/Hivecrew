//
//  LLMToolCall.swift
//  HivecrewLLM
//
//  Types for LLM tool/function calling
//

import Foundation

/// A tool call requested by the LLM
public struct LLMToolCall: Sendable, Codable, Equatable {
    /// Unique identifier for this tool call
    public let id: String
    
    /// Type of tool (currently always "function")
    public let type: String
    
    /// The function being called
    public let function: LLMFunctionCall
    
    public init(id: String, type: String = "function", function: LLMFunctionCall) {
        self.id = id
        self.type = type
        self.function = function
    }
}

/// A function call within a tool call
public struct LLMFunctionCall: Sendable, Codable, Equatable {
    /// Name of the function to call
    public let name: String
    
    /// JSON-encoded arguments for the function
    public let arguments: String
    
    public init(name: String, arguments: String) {
        self.name = name
        self.arguments = arguments
    }
    
    /// Parse arguments as a dictionary
    public func argumentsDictionary() throws -> [String: Any] {
        guard let data = arguments.data(using: .utf8) else {
            throw LLMError.invalidToolArguments("Arguments not valid UTF-8")
        }
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.invalidToolArguments("Arguments not a JSON object")
        }
        return dict
    }
    
    /// Parse arguments and decode to a specific type
    public func decodeArguments<T: Decodable>(_ type: T.Type) throws -> T {
        guard let data = arguments.data(using: .utf8) else {
            throw LLMError.invalidToolArguments("Arguments not valid UTF-8")
        }
        return try JSONDecoder().decode(type, from: data)
    }
}

/// Definition of a tool that can be used by the LLM
public struct LLMToolDefinition: Sendable, Codable, Equatable {
    /// Type of tool (currently always "function")
    public let type: String
    
    /// The function definition
    public let function: LLMFunctionDefinition
    
    public init(type: String = "function", function: LLMFunctionDefinition) {
        self.type = type
        self.function = function
    }
    
    /// Convenience initializer for function tools
    public static func function(
        name: String,
        description: String,
        parameters: [String: Any]
    ) -> LLMToolDefinition {
        LLMToolDefinition(
            type: "function",
            function: LLMFunctionDefinition(
                name: name,
                description: description,
                parameters: parameters
            )
        )
    }
}

/// Definition of a function that can be called by the LLM
public struct LLMFunctionDefinition: Sendable, Equatable {
    /// Name of the function
    public let name: String
    
    /// Description of what the function does
    public let description: String
    
    /// JSON Schema for the function parameters (stored as JSONValue for Sendable conformance)
    public let parametersValue: JSONValue
    
    /// JSON Schema for the function parameters as dictionary
    public var parameters: [String: Any] {
        parametersValue.toDictionary() ?? [:]
    }
    
    public init(name: String, description: String, parameters: [String: Any]) {
        self.name = name
        self.description = description
        self.parametersValue = JSONValue.from(parameters)
    }
    
    public init(name: String, description: String, parametersValue: JSONValue) {
        self.name = name
        self.description = description
        self.parametersValue = parametersValue
    }
}

// Custom Codable for LLMFunctionDefinition
extension LLMFunctionDefinition: Codable {
    enum CodingKeys: String, CodingKey {
        case name
        case description
        case parameters
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decode(String.self, forKey: .description)
        parametersValue = try container.decode(JSONValue.self, forKey: .parameters)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        try container.encode(parametersValue, forKey: .parameters)
    }
}

/// Helper type for encoding/decoding arbitrary JSON
public enum JSONValue: Sendable, Codable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown JSON value")
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
    
    /// Convert to Any for use with JSONSerialization
    public func toAny() -> Any {
        switch self {
        case .null:
            return NSNull()
        case .bool(let value):
            return value
        case .int(let value):
            return value
        case .double(let value):
            return value
        case .string(let value):
            return value
        case .array(let value):
            return value.map { $0.toAny() }
        case .object(let value):
            return value.mapValues { $0.toAny() }
        }
    }
    
    /// Convert to dictionary if this is an object
    public func toDictionary() -> [String: Any]? {
        if case .object(let dict) = self {
            return dict.mapValues { $0.toAny() }
        }
        return nil
    }
    
    /// Create from Any (for JSON serialization)
    public static func from(_ value: Any) -> JSONValue {
        switch value {
        case is NSNull:
            return .null
        case let bool as Bool:
            return .bool(bool)
        case let int as Int:
            return .int(int)
        case let double as Double:
            return .double(double)
        case let string as String:
            return .string(string)
        case let array as [Any]:
            return .array(array.map { from($0) })
        case let dict as [String: Any]:
            return .object(dict.mapValues { from($0) })
        default:
            return .null
        }
    }
}
