//
//  MCPTypes.swift
//  HivecrewMCP
//
//  Core types for the Model Context Protocol (MCP)
//

import Foundation

// MARK: - Transport Type

/// The transport mechanism used to communicate with an MCP server
public enum MCPTransportType: String, Codable, Sendable {
    case stdio = "stdio"
    case http = "http"
}

// MARK: - JSON-RPC Types

/// JSON-RPC 2.0 request structure
public struct MCPRequest: Codable, Sendable {
    public let jsonrpc: String
    public let id: Int
    public let method: String
    public let params: [String: AnyCodableValue]?
    
    public init(id: Int, method: String, params: [String: AnyCodableValue]? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }
}

/// JSON-RPC 2.0 response structure
public struct MCPResponse: Codable, Sendable {
    public let jsonrpc: String
    public let id: Int?
    public let result: AnyCodableValue?
    public let error: MCPError?
    
    public init(id: Int?, result: AnyCodableValue? = nil, error: MCPError? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = error
    }
}

/// JSON-RPC 2.0 error
public struct MCPError: Codable, Sendable, Error {
    public let code: Int
    public let message: String
    public let data: AnyCodableValue?
    
    public init(code: Int, message: String, data: AnyCodableValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

// MARK: - MCP Protocol Types

/// MCP server capabilities
public struct MCPServerCapabilities: Codable, Sendable {
    public let tools: MCPToolsCapability?
    public let resources: MCPResourcesCapability?
    public let prompts: MCPPromptsCapability?
    
    public init(tools: MCPToolsCapability? = nil, resources: MCPResourcesCapability? = nil, prompts: MCPPromptsCapability? = nil) {
        self.tools = tools
        self.resources = resources
        self.prompts = prompts
    }
}

public struct MCPToolsCapability: Codable, Sendable {
    public let listChanged: Bool?
    
    public init(listChanged: Bool? = nil) {
        self.listChanged = listChanged
    }
}

public struct MCPResourcesCapability: Codable, Sendable {
    public let subscribe: Bool?
    public let listChanged: Bool?
    
    public init(subscribe: Bool? = nil, listChanged: Bool? = nil) {
        self.subscribe = subscribe
        self.listChanged = listChanged
    }
}

public struct MCPPromptsCapability: Codable, Sendable {
    public let listChanged: Bool?
    
    public init(listChanged: Bool? = nil) {
        self.listChanged = listChanged
    }
}

/// MCP client capabilities
public struct MCPClientCapabilities: Codable, Sendable {
    public let roots: MCPRootsCapability?
    public let sampling: [String: AnyCodableValue]?
    
    public init(roots: MCPRootsCapability? = nil, sampling: [String: AnyCodableValue]? = nil) {
        self.roots = roots
        self.sampling = sampling
    }
}

public struct MCPRootsCapability: Codable, Sendable {
    public let listChanged: Bool?
    
    public init(listChanged: Bool? = nil) {
        self.listChanged = listChanged
    }
}

/// MCP client info
public struct MCPClientInfo: Codable, Sendable {
    public let name: String
    public let version: String
    
    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

/// MCP server info
public struct MCPServerInfo: Codable, Sendable {
    public let name: String
    public let version: String
    
    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

/// Initialize request parameters
public struct MCPInitializeParams: Codable, Sendable {
    public let protocolVersion: String
    public let capabilities: MCPClientCapabilities
    public let clientInfo: MCPClientInfo
    
    public init(protocolVersion: String, capabilities: MCPClientCapabilities, clientInfo: MCPClientInfo) {
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.clientInfo = clientInfo
    }
}

/// Initialize response result
public struct MCPInitializeResult: Codable, Sendable {
    public let protocolVersion: String
    public let capabilities: MCPServerCapabilities
    public let serverInfo: MCPServerInfo?
    
    public init(protocolVersion: String, capabilities: MCPServerCapabilities, serverInfo: MCPServerInfo? = nil) {
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.serverInfo = serverInfo
    }
}

// MARK: - Tool Types

/// An MCP tool definition
public struct MCPTool: Codable, Sendable, Identifiable {
    public let name: String
    public let description: String?
    public let inputSchema: MCPToolInputSchema
    
    public var id: String { name }
    
    public init(name: String, description: String?, inputSchema: MCPToolInputSchema) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// Tool input schema (JSON Schema)
public struct MCPToolInputSchema: Codable, Sendable {
    public let type: String
    public let properties: [String: AnyCodableValue]?
    public let required: [String]?
    public let additionalProperties: Bool?
    
    public init(type: String = "object", properties: [String: AnyCodableValue]? = nil, required: [String]? = nil, additionalProperties: Bool? = nil) {
        self.type = type
        self.properties = properties
        self.required = required
        self.additionalProperties = additionalProperties
    }
    
    /// Convert to dictionary for LLM tool definition
    public func toDictionary() -> [String: Any] {
        var dict: [String: Any] = ["type": type]
        if let props = properties {
            dict["properties"] = props.mapValues { $0.toAny() }
        }
        if let req = required {
            dict["required"] = req
        }
        if let addProps = additionalProperties {
            dict["additionalProperties"] = addProps
        }
        return dict
    }
}

/// List tools response
public struct MCPListToolsResult: Codable, Sendable {
    public let tools: [MCPTool]
    public let nextCursor: String?
    
    public init(tools: [MCPTool], nextCursor: String? = nil) {
        self.tools = tools
        self.nextCursor = nextCursor
    }
}

/// Call tool parameters
public struct MCPCallToolParams: Codable, Sendable {
    public let name: String
    public let arguments: [String: AnyCodableValue]?
    
    public init(name: String, arguments: [String: AnyCodableValue]? = nil) {
        self.name = name
        self.arguments = arguments
    }
}

/// Tool call result content
public struct MCPToolContent: Codable, Sendable {
    public let type: String
    public let text: String?
    public let mimeType: String?
    public let data: String? // Base64 encoded for images/binary
    
    public init(type: String, text: String? = nil, mimeType: String? = nil, data: String? = nil) {
        self.type = type
        self.text = text
        self.mimeType = mimeType
        self.data = data
    }
}

/// Call tool response
public struct MCPCallToolResult: Codable, Sendable {
    public let content: [MCPToolContent]
    public let isError: Bool?
    
    public init(content: [MCPToolContent], isError: Bool? = nil) {
        self.content = content
        self.isError = isError
    }
    
    /// Get text content from the result
    public var textContent: String {
        content.compactMap { $0.text }.joined(separator: "\n")
    }
}

// MARK: - AnyCodableValue

/// Type-erased Codable value for JSON handling
public enum AnyCodableValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([AnyCodableValue])
    case object([String: AnyCodableValue])
    
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
        } else if let array = try? container.decode([AnyCodableValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: AnyCodableValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unable to decode value")
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
    
    /// Convert to Any for use with existing APIs
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
    
    /// Create from Any value
    public static func from(_ value: Any) -> AnyCodableValue {
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
            return .string(String(describing: value))
        }
    }
}

// MARK: - MCP Errors

/// MCP-specific error codes
public enum MCPErrorCode: Int {
    case parseError = -32700
    case invalidRequest = -32600
    case methodNotFound = -32601
    case invalidParams = -32602
    case internalError = -32603
    
    // Custom MCP errors
    case connectionFailed = -1001
    case timeout = -1002
    case serverNotInitialized = -1003
    case toolNotFound = -1004
}

/// MCP client errors
public enum MCPClientError: Error, LocalizedError {
    case connectionFailed(String)
    case timeout
    case notInitialized
    case invalidResponse(String)
    case serverError(MCPError)
    case toolNotFound(String)
    case encodingError(String)
    case processSpawnFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let reason):
            return "MCP connection failed: \(reason)"
        case .timeout:
            return "MCP request timed out"
        case .notInitialized:
            return "MCP server not initialized"
        case .invalidResponse(let reason):
            return "Invalid MCP response: \(reason)"
        case .serverError(let error):
            return "MCP server error: \(error.message)"
        case .toolNotFound(let name):
            return "MCP tool not found: \(name)"
        case .encodingError(let reason):
            return "MCP encoding error: \(reason)"
        case .processSpawnFailed(let reason):
            return "Failed to spawn MCP server process: \(reason)"
        }
    }
}
