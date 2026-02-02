//
//  MCPServerManager.swift
//  Hivecrew
//
//  Manages MCP server connections and provides access to their tools
//

import Combine
import Foundation
import OSLog
import SwiftData
import HivecrewMCP
import HivecrewLLM

/// Logger for MCP debugging
private let mcpLogger = Logger(subsystem: "com.pattonium.Hivecrew", category: "MCP")

/// Manages the lifecycle of MCP server connections
@MainActor
final class MCPServerManager: ObservableObject {
    
    /// Shared instance
    static let shared = MCPServerManager()
    
    /// Active server connections keyed by server ID
    private var connections: [String: MCPServerConnection] = [:]
    
    /// Published state for UI updates
    @Published private(set) var serverStates: [String: MCPConnectionState] = [:]
    
    /// Whether any servers are currently connecting
    @Published private(set) var isConnecting = false
    
    /// Model context for fetching server records
    private var modelContext: ModelContext?
    
    private init() {}
    
    /// Configure the manager with the model context
    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
    }
    
    // MARK: - Connection Management
    
    /// Connect to all enabled MCP servers
    func connectAllEnabled() async {
        mcpLogger.info("connectAllEnabled: Starting")
        
        guard let modelContext = modelContext else {
            mcpLogger.warning("connectAllEnabled: Not configured - no modelContext")
            return
        }
        mcpLogger.info("connectAllEnabled: Have modelContext")
        
        isConnecting = true
        defer { isConnecting = false }
        
        mcpLogger.info("connectAllEnabled: Creating fetch descriptor")
        
        // Fetch all enabled servers
        let descriptor = FetchDescriptor<MCPServerRecord>(
            predicate: #Predicate { $0.isEnabled }
        )
        
        mcpLogger.info("connectAllEnabled: Fetching servers")
        
        guard let servers = try? modelContext.fetch(descriptor) else {
            mcpLogger.error("connectAllEnabled: Failed to fetch server records")
            return
        }
        
        mcpLogger.info("connectAllEnabled: Found \(servers.count) enabled servers")
        
        // If no servers, exit early
        if servers.isEmpty {
            mcpLogger.info("connectAllEnabled: No servers to connect, exiting")
            return
        }
        
        mcpLogger.info("connectAllEnabled: Extracting configs")
        
        // Extract configs from SwiftData models before entering concurrent tasks
        // (SwiftData models are not thread-safe)
        let serverConfigs = servers.map { ($0.id, $0.toConfig()) }
        
        mcpLogger.info("connectAllEnabled: Extracted \(serverConfigs.count) configs")
        
        mcpLogger.info("connectAllEnabled: Connecting to servers sequentially")
        
        // Connect to each server sequentially (avoid actor isolation issues with task groups)
        for (serverId, config) in serverConfigs {
            mcpLogger.info("connectAllEnabled: Connecting to \(config.name)")
            await connectWithConfig(serverId: serverId, config: config)
        }
        
        mcpLogger.info("connectAllEnabled: All connections attempted")
        
        // Update last connected dates on the main context
        for server in servers {
            if case .connected = serverStates[server.id] {
                server.lastConnectedAt = Date()
            }
        }
        try? modelContext.save()
        
        mcpLogger.info("connectAllEnabled: Completed")
    }
    
    /// Connect to a specific server using its config
    private func connectWithConfig(serverId: String, config: MCPServerConfig) async {
        mcpLogger.info("connectWithConfig: Creating connection for \(config.name)")
        let connection = MCPServerConnection(config: config)
        
        mcpLogger.info("connectWithConfig: Storing connection")
        // Store connection
        connections[serverId] = connection
        serverStates[serverId] = .connecting
        
        mcpLogger.info("connectWithConfig: Calling connection.connect()")
        do {
            try await connection.connect()
            mcpLogger.info("connectWithConfig: connection.connect() completed")
            
            let state = await connection.state
            serverStates[serverId] = state
            mcpLogger.info("connectWithConfig: Got state")
            
            let tools = await connection.tools
            mcpLogger.info("connectWithConfig: Connected to '\(config.name)' with \(tools.count) tools")
        } catch {
            mcpLogger.error("connectWithConfig: Failed to connect to '\(config.name)': \(error.localizedDescription)")
            serverStates[serverId] = .error(error.localizedDescription)
        }
    }
    
    /// Disconnect from a specific server
    func disconnect(from serverId: String) async {
        guard let connection = connections[serverId] else { return }
        
        await connection.disconnect()
        connections.removeValue(forKey: serverId)
        serverStates[serverId] = .disconnected
    }
    
    /// Disconnect from all servers
    func disconnectAll() async {
        for (serverId, connection) in connections {
            await connection.disconnect()
            serverStates[serverId] = .disconnected
        }
        connections.removeAll()
    }
    
    /// Reconnect to a server
    func reconnect(serverId: String) async {
        guard let modelContext = modelContext else { return }
        
        // Disconnect first
        await disconnect(from: serverId)
        
        // Fetch the server record
        let id = serverId
        let descriptor = FetchDescriptor<MCPServerRecord>(
            predicate: #Predicate { $0.id == id }
        )
        
        guard let server = try? modelContext.fetch(descriptor).first else {
            print("[MCPServerManager] Server not found: \(serverId)")
            return
        }
        
        // Extract config before async work
        let config = server.toConfig()
        await connectWithConfig(serverId: serverId, config: config)
        
        // Update last connected if successful
        if case .connected = serverStates[serverId] {
            server.lastConnectedAt = Date()
            try? modelContext.save()
        }
    }
    
    // MARK: - Tool Access
    
    /// Get all available tools from connected servers
    func getAllTools() async -> [LLMToolDefinition] {
        var tools: [LLMToolDefinition] = []
        
        for (_, connection) in connections {
            let isConnected = await connection.isConnected
            guard isConnected else { continue }
            
            let prefixedTools = await connection.prefixedTools
            for mcpTool in prefixedTools {
                let llmTool = LLMToolDefinition.function(
                    name: mcpTool.name,
                    description: mcpTool.description ?? mcpTool.name,
                    parameters: mcpTool.inputSchema.toDictionary()
                )
                tools.append(llmTool)
            }
        }
        
        return tools
    }
    
    /// Get tools from a specific server
    func getTools(for serverId: String) async -> [MCPTool] {
        guard let connection = connections[serverId] else { return [] }
        return await connection.tools
    }
    
    /// Check if a tool name belongs to an MCP server
    func isMCPTool(_ toolName: String) -> Bool {
        toolName.hasPrefix("mcp_")
    }
    
    /// Execute an MCP tool call
    func executeTool(name: String, arguments: [String: Any]) async throws -> MCPCallToolResult {
        // Find the server that owns this tool
        for (_, connection) in connections {
            let owns = await connection.ownsToolName(name)
            if owns {
                // Extract the original tool name
                guard let originalName = await connection.extractToolName(from: name) else {
                    throw MCPClientError.toolNotFound(name)
                }
                
                return try await connection.callTool(name: originalName, arguments: arguments)
            }
        }
        
        throw MCPClientError.toolNotFound(name)
    }
    
    // MARK: - Server Status
    
    /// Get the connection state for a server
    func getState(for serverId: String) -> MCPConnectionState {
        serverStates[serverId] ?? .disconnected
    }
    
    /// Check if a server is connected
    func isConnected(serverId: String) async -> Bool {
        guard let connection = connections[serverId] else { return false }
        return await connection.isConnected
    }
    
    /// Get the number of tools available from a server
    func getToolCount(for serverId: String) async -> Int {
        guard let connection = connections[serverId] else { return 0 }
        return await connection.tools.count
    }
    
    /// Get all connected server IDs
    var connectedServerIds: [String] {
        connections.keys.filter { serverId in
            if case .connected = serverStates[serverId] {
                return true
            }
            return false
        }
    }
    
    /// Refresh tools from all connected servers
    func refreshAllTools() async {
        for (_, connection) in connections {
            let isConnected = await connection.isConnected
            if isConnected {
                try? await connection.refreshTools()
            }
        }
    }
}

// MARK: - Convenience Extensions

extension MCPServerManager {
    /// Get a summary of connected servers for logging
    func getConnectionSummary() async -> String {
        var lines: [String] = []
        
        for (_, connection) in connections {
            let state = await connection.state
            let toolCount = await connection.tools.count
            let name = connection.config.name
            
            let stateStr: String
            switch state {
            case .disconnected: stateStr = "disconnected"
            case .connecting: stateStr = "connecting"
            case .connected: stateStr = "connected (\(toolCount) tools)"
            case .error(let msg): stateStr = "error: \(msg)"
            }
            
            lines.append("  - \(name): \(stateStr)")
        }
        
        if lines.isEmpty {
            return "No MCP servers configured"
        }
        
        return "MCP Servers:\n" + lines.joined(separator: "\n")
    }
}
