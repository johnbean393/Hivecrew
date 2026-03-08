//
//  MCPErrors.swift
//  HivecrewMCP
//
//  Error codes and client error wrappers for MCP interactions
//

import Foundation

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
