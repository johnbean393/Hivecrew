//
//  MCPServerRecord.swift
//  Hivecrew
//
//  SwiftData model for persisting MCP server configurations
//

import Foundation
import SwiftData

/// Transport type for MCP server communication
enum MCPServerTransportType: String, Codable, CaseIterable {
    case stdio = "stdio"
    case http = "http"
    
    var displayName: String {
        switch self {
        case .stdio: return String(localized: "Standard I/O (Local Process)")
        case .http: return String(localized: "HTTP (Remote Server)")
        }
    }
}

/// SwiftData model for persisting MCP server configurations
@Model
final class MCPServerRecord {
    /// Unique identifier for this server
    @Attribute(.unique) var id: String
    
    /// Human-readable display name
    var displayName: String
    
    /// Whether this server is enabled (tools will be included in LLM calls)
    var isEnabled: Bool
    
    /// Transport type (stdio or http)
    var transportTypeRaw: String
    
    // MARK: - Stdio Transport Configuration
    
    /// Command to execute (e.g., "npx", "node", "/usr/local/bin/mcp-server")
    var command: String?
    
    /// Command line arguments (stored as JSON array)
    var argumentsJSON: String?
    
    /// Working directory for the process
    var workingDirectory: String?
    
    /// Environment variables (stored as JSON object)
    var environmentJSON: String?
    
    // MARK: - HTTP Transport Configuration
    
    /// Server URL for HTTP transport
    var serverURL: String?
    
    // MARK: - Metadata
    
    /// When this server was added
    var createdAt: Date
    
    /// When this server was last successfully connected
    var lastConnectedAt: Date?
    
    /// Order for display in lists
    var sortOrder: Int
    
    init(
        id: String = UUID().uuidString,
        displayName: String,
        isEnabled: Bool = true,
        transportType: MCPServerTransportType = .stdio,
        command: String? = nil,
        arguments: [String]? = nil,
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        serverURL: String? = nil,
        createdAt: Date = Date(),
        lastConnectedAt: Date? = nil,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.displayName = displayName
        self.isEnabled = isEnabled
        self.transportTypeRaw = transportType.rawValue
        self.command = command
        self.argumentsJSON = arguments.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        self.workingDirectory = workingDirectory
        self.environmentJSON = environment.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        self.serverURL = serverURL
        self.createdAt = createdAt
        self.lastConnectedAt = lastConnectedAt
        self.sortOrder = sortOrder
    }
    
    // MARK: - Computed Properties
    
    /// Transport type as enum
    var transportType: MCPServerTransportType {
        get {
            MCPServerTransportType(rawValue: transportTypeRaw) ?? .stdio
        }
        set {
            transportTypeRaw = newValue.rawValue
        }
    }
    
    /// Arguments as array
    var arguments: [String] {
        get {
            guard let json = argumentsJSON,
                  let data = json.data(using: .utf8),
                  let args = try? JSONDecoder().decode([String].self, from: data) else {
                return []
            }
            return args
        }
        set {
            argumentsJSON = (try? JSONEncoder().encode(newValue)).flatMap { String(data: $0, encoding: .utf8) }
        }
    }
    
    /// Environment variables as dictionary
    var environment: [String: String] {
        get {
            guard let json = environmentJSON,
                  let data = json.data(using: .utf8),
                  let env = try? JSONDecoder().decode([String: String].self, from: data) else {
                return [:]
            }
            return env
        }
        set {
            environmentJSON = (try? JSONEncoder().encode(newValue)).flatMap { String(data: $0, encoding: .utf8) }
        }
    }
    
    /// A display label showing server name and transport type
    var displayLabel: String {
        "\(displayName) (\(transportType.displayName))"
    }
    
    /// Sanitized server name for use in tool prefixes
    var sanitizedName: String {
        displayName
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
    }
    
    /// Whether this server configuration is valid
    var isValid: Bool {
        switch transportType {
        case .stdio:
            guard let cmd = command, !cmd.isEmpty else { return false }
            return true
        case .http:
            guard let url = serverURL, URL(string: url) != nil else { return false }
            return true
        }
    }
}

// MARK: - Configuration Conversion

import HivecrewMCP

extension MCPServerRecord {
    /// Convert to MCPServerConfig for use with MCPServerConnection
    func toConfig() -> MCPServerConfig {
        MCPServerConfig(
            id: UUID(uuidString: id) ?? UUID(),
            name: displayName,
            transportType: transportType == .stdio ? .stdio : .http,
            command: command,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment.isEmpty ? nil : environment,
            serverURL: serverURL
        )
    }
}

// MARK: - Presets

extension MCPServerRecord {
    /// Create a preset for the filesystem MCP server
    static func filesystemPreset() -> MCPServerRecord {
        MCPServerRecord(
            displayName: "Filesystem",
            transportType: .stdio,
            command: "npx",
            arguments: ["-y", "@modelcontextprotocol/server-filesystem", NSHomeDirectory()]
        )
    }
    
    /// Create a preset for the GitHub MCP server
    static func githubPreset() -> MCPServerRecord {
        MCPServerRecord(
            displayName: "GitHub",
            transportType: .stdio,
            command: "npx",
            arguments: ["-y", "@modelcontextprotocol/server-github"]
        )
    }
    
    /// Create a preset for the Brave Search MCP server
    static func braveSearchPreset() -> MCPServerRecord {
        MCPServerRecord(
            displayName: "Brave Search",
            transportType: .stdio,
            command: "npx",
            arguments: ["-y", "@modelcontextprotocol/server-brave-search"]
        )
    }
}
