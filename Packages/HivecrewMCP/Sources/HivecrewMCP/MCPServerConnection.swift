//
//  MCPServerConnection.swift
//  HivecrewMCP
//
//  Manages the lifecycle of a connection to a single MCP server
//

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.pattonium.mcp", category: "MCPServerConnection")

/// Configuration for an MCP server connection
public struct MCPServerConfig: Sendable {
    public let id: UUID
    public let name: String
    public let transportType: MCPTransportType
    
    // Stdio transport config
    public let command: String?
    public let arguments: [String]
    public let workingDirectory: String?
    public let environment: [String: String]?
    
    // HTTP transport config
    public let serverURL: String?
    
    public init(
        id: UUID = UUID(),
        name: String,
        transportType: MCPTransportType,
        command: String? = nil,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        serverURL: String? = nil
    ) {
        self.id = id
        self.name = name
        self.transportType = transportType
        self.command = command
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.serverURL = serverURL
    }
}

/// State of an MCP server connection
public enum MCPConnectionState: Sendable {
    case disconnected
    case connecting
    case connected
    case error(String)
}

/// Manages a connection to a single MCP server
public actor MCPServerConnection {
    public nonisolated let config: MCPServerConfig
    
    private var client: MCPClient?
    private var _state: MCPConnectionState = .disconnected
    private var _tools: [MCPTool] = []
    
    public var state: MCPConnectionState { _state }
    public var tools: [MCPTool] { _tools }
    public var isConnected: Bool {
        if case .connected = _state { return true }
        return false
    }
    
    public init(config: MCPServerConfig) {
        self.config = config
    }
    
    /// Connect to the MCP server
    public func connect() async throws {
        logger.info("connect: Starting for \(self.config.name)")
        
        guard case .disconnected = _state else {
            logger.info("connect: Already connected or connecting, returning")
            return
        }
        
        _state = .connecting
        logger.info("connect: State set to connecting")
        
        do {
            logger.info("connect: Creating client")
            let mcpClient = try createClient()
            logger.info("connect: Client created")
            
            self.client = mcpClient
            logger.info("connect: Client stored, calling start()")
            
            try await mcpClient.start()
            logger.info("connect: start() completed")
            
            // Fetch available tools
            logger.info("connect: Listing tools")
            let tools = try await mcpClient.listTools()
            _tools = tools
            logger.info("connect: Got \(tools.count) tools")
            
            _state = .connected
            logger.info("connect: Connected successfully")
        } catch {
            logger.error("connect: Error - \(error.localizedDescription)")
            _state = .error(error.localizedDescription)
            throw error
        }
    }
    
    /// Disconnect from the MCP server
    public func disconnect() async {
        if let client = client {
            try? await client.stop()
        }
        client = nil
        _tools = []
        _state = .disconnected
        print("[MCP] Disconnected from '\(config.name)'")
    }
    
    /// Call a tool on this server
    public func callTool(name: String, arguments: [String: Any]) async throws -> MCPCallToolResult {
        guard let client = client else {
            throw MCPClientError.notInitialized
        }
        
        // Convert to Sendable type before crossing actor boundary
        let sendableArgs = arguments.mapValues { AnyCodableValue.from($0) }
        return try await client.callTool(name: name, arguments: sendableArgs)
    }
    
    /// Refresh the tools list from the server
    public func refreshTools() async throws {
        guard let client = client else {
            throw MCPClientError.notInitialized
        }
        
        await client.invalidateToolsCache()
        _tools = try await client.listTools()
    }
    
    // MARK: - Private
    
    private func createClient() throws -> MCPClient {
        switch config.transportType {
        case .stdio:
            guard let command = config.command, !command.isEmpty else {
                throw MCPClientError.connectionFailed("No command specified for stdio transport")
            }
            return MCPClient(
                command: command,
                arguments: config.arguments,
                workingDirectory: config.workingDirectory,
                environment: config.environment
            )
            
        case .http:
            guard let urlString = config.serverURL,
                  let url = URL(string: urlString) else {
                throw MCPClientError.connectionFailed("Invalid or missing URL for HTTP transport")
            }
            return MCPClient(serverURL: url)
        }
    }
}

// MARK: - Tool Prefix Helpers

extension MCPServerConnection {
    /// Get the prefixed name for a tool (mcp_{serverName}_{toolName})
    public func prefixedToolName(_ toolName: String) -> String {
        let sanitizedServerName = config.name
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
        return "mcp_\(sanitizedServerName)_\(toolName)"
    }
    
    /// Get tools with prefixed names for this server
    public var prefixedTools: [MCPTool] {
        _tools.map { tool in
            MCPTool(
                name: prefixedToolName(tool.name),
                description: "[\(config.name)] \(tool.description ?? tool.name)",
                inputSchema: tool.inputSchema
            )
        }
    }
    
    /// Check if a prefixed tool name belongs to this server
    public func ownsToolName(_ prefixedName: String) -> Bool {
        let sanitizedServerName = config.name
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
        return prefixedName.hasPrefix("mcp_\(sanitizedServerName)_")
    }
    
    /// Extract the original tool name from a prefixed name
    public func extractToolName(from prefixedName: String) -> String? {
        let sanitizedServerName = config.name
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
        let prefix = "mcp_\(sanitizedServerName)_"
        
        guard prefixedName.hasPrefix(prefix) else {
            return nil
        }
        
        return String(prefixedName.dropFirst(prefix.count))
    }
}
