//
//  MCPJSONRPCTypes.swift
//  HivecrewMCP
//
//  JSON-RPC transport and message envelope types for MCP
//

import Foundation

/// The transport mechanism used to communicate with an MCP server
public enum MCPTransportType: String, Codable, Sendable {
    case stdio = "stdio"
    case http = "http"
}

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
