//
//  MCPToolTypes.swift
//  HivecrewMCP
//
//  Tool schema and invocation result types for MCP
//

import Foundation

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
