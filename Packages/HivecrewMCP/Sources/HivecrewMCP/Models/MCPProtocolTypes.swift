//
//  MCPProtocolTypes.swift
//  HivecrewMCP
//
//  Core protocol capability and initialization types for MCP
//

import Foundation

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
