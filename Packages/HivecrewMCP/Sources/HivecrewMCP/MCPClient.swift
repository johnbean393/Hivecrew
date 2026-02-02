//
//  MCPClient.swift
//  HivecrewMCP
//
//  Core MCP client implementation
//

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.pattonium.mcp", category: "MCPClient")

/// MCP protocol version
private let MCP_PROTOCOL_VERSION = "2024-11-05"

/// MCP client for communicating with MCP servers
public actor MCPClient {
    private let transport: MCPTransport
    private var requestId: Int = 0
    private var serverCapabilities: MCPServerCapabilities?
    private var serverInfo: MCPServerInfo?
    private var cachedTools: [MCPTool]?
    
    public var isInitialized: Bool { serverCapabilities != nil }
    
    public init(transport: MCPTransport) {
        self.transport = transport
    }
    
    /// Convenience initializer for stdio transport
    public init(command: String, arguments: [String] = [], workingDirectory: String? = nil, environment: [String: String]? = nil) {
        self.transport = StdioTransport(
            command: command,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment
        )
    }
    
    /// Convenience initializer for HTTP transport
    public init(serverURL: URL) {
        self.transport = HTTPTransport(serverURL: serverURL)
    }
    
    // MARK: - Lifecycle
    
    /// Start the client and initialize the connection
    public func start() async throws {
        logger.info("start: Beginning")
        logger.info("start: Calling transport.start()")
        try await transport.start()
        logger.info("start: transport.start() completed")
        logger.info("start: Calling initialize()")
        try await initialize()
        logger.info("start: initialize() completed")
    }
    
    /// Stop the client and close the connection
    public func stop() async throws {
        try await transport.stop()
        serverCapabilities = nil
        serverInfo = nil
        cachedTools = nil
    }
    
    // MARK: - Initialization
    
    private func initialize() async throws {
        logger.info("initialize: Starting")
        
        let clientInfo = MCPClientInfo(name: "Hivecrew", version: "1.0.0")
        let capabilities = MCPClientCapabilities(
            roots: MCPRootsCapability(listChanged: true),
            sampling: nil
        )
        
        let params = MCPInitializeParams(
            protocolVersion: MCP_PROTOCOL_VERSION,
            capabilities: capabilities,
            clientInfo: clientInfo
        )
        logger.info("initialize: Params created")
        
        let paramsDict: [String: AnyCodableValue] = [
            "protocolVersion": .string(params.protocolVersion),
            "capabilities": encodeCapabilities(params.capabilities),
            "clientInfo": .object([
                "name": .string(params.clientInfo.name),
                "version": .string(params.clientInfo.version)
            ])
        ]
        logger.info("initialize: Calling sendRequest for 'initialize'")
        
        let response = try await sendRequest(method: "initialize", params: paramsDict)
        logger.info("initialize: Got response")
        
        guard let result = response.result else {
            if let error = response.error {
                logger.error("initialize: Server error - \(error.message)")
                throw MCPClientError.serverError(error)
            }
            logger.error("initialize: No result in response")
            throw MCPClientError.invalidResponse("No result in initialize response")
        }
        logger.info("initialize: Parsing result")
        
        // Parse the result
        let initResult = try decodeInitializeResult(from: result)
        self.serverCapabilities = initResult.capabilities
        self.serverInfo = initResult.serverInfo
        logger.info("initialize: Parsed, sending initialized notification")
        
        // Send initialized notification
        try await sendNotification(method: "notifications/initialized", params: nil)
        logger.info("initialize: Complete")
    }
    
    private func encodeCapabilities(_ caps: MCPClientCapabilities) -> AnyCodableValue {
        var dict: [String: AnyCodableValue] = [:]
        if let roots = caps.roots {
            dict["roots"] = .object(["listChanged": .bool(roots.listChanged ?? false)])
        }
        return .object(dict)
    }
    
    private func decodeInitializeResult(from value: AnyCodableValue) throws -> MCPInitializeResult {
        guard case .object(let dict) = value else {
            throw MCPClientError.invalidResponse("Expected object in initialize result")
        }
        
        guard case .string(let version) = dict["protocolVersion"] else {
            throw MCPClientError.invalidResponse("Missing protocolVersion")
        }
        
        let caps = decodeServerCapabilities(dict["capabilities"])
        let info = decodeServerInfo(dict["serverInfo"])
        
        return MCPInitializeResult(
            protocolVersion: version,
            capabilities: caps,
            serverInfo: info
        )
    }
    
    private func decodeServerCapabilities(_ value: AnyCodableValue?) -> MCPServerCapabilities {
        guard case .object(let dict) = value else {
            return MCPServerCapabilities()
        }
        
        var tools: MCPToolsCapability?
        if case .object(let toolsDict) = dict["tools"] {
            var listChanged: Bool?
            if case .bool(let v) = toolsDict["listChanged"] {
                listChanged = v
            }
            tools = MCPToolsCapability(listChanged: listChanged)
        }
        
        return MCPServerCapabilities(tools: tools)
    }
    
    private func decodeServerInfo(_ value: AnyCodableValue?) -> MCPServerInfo? {
        guard case .object(let dict) = value,
              case .string(let name) = dict["name"],
              case .string(let version) = dict["version"] else {
            return nil
        }
        return MCPServerInfo(name: name, version: version)
    }
    
    // MARK: - Tools
    
    /// List available tools from the server
    public func listTools() async throws -> [MCPTool] {
        if let cached = cachedTools {
            return cached
        }
        
        let response = try await sendRequest(method: "tools/list", params: nil)
        
        if let error = response.error {
            throw MCPClientError.serverError(error)
        }
        
        guard let result = response.result else {
            throw MCPClientError.invalidResponse("No result in tools/list response")
        }
        
        let tools = try decodeToolsListResult(from: result)
        cachedTools = tools
        return tools
    }
    
    private func decodeToolsListResult(from value: AnyCodableValue) throws -> [MCPTool] {
        guard case .object(let dict) = value,
              case .array(let toolsArray) = dict["tools"] else {
            throw MCPClientError.invalidResponse("Invalid tools/list result format")
        }
        
        return try toolsArray.compactMap { try decodeTool(from: $0) }
    }
    
    private func decodeTool(from value: AnyCodableValue) throws -> MCPTool? {
        guard case .object(let dict) = value,
              case .string(let name) = dict["name"] else {
            return nil
        }
        
        var description: String?
        if case .string(let desc) = dict["description"] {
            description = desc
        }
        
        let inputSchema: MCPToolInputSchema
        if case .object(let schemaDict) = dict["inputSchema"] {
            inputSchema = decodeInputSchema(from: schemaDict)
        } else {
            inputSchema = MCPToolInputSchema()
        }
        
        return MCPTool(name: name, description: description, inputSchema: inputSchema)
    }
    
    private func decodeInputSchema(from dict: [String: AnyCodableValue]) -> MCPToolInputSchema {
        var type = "object"
        if case .string(let t) = dict["type"] {
            type = t
        }
        
        var properties: [String: AnyCodableValue]?
        if case .object(let props) = dict["properties"] {
            properties = props
        }
        
        var required: [String]?
        if case .array(let req) = dict["required"] {
            required = req.compactMap { value -> String? in
                if case .string(let s) = value { return s }
                return nil
            }
        }
        
        var additionalProperties: Bool?
        if case .bool(let v) = dict["additionalProperties"] {
            additionalProperties = v
        }
        
        return MCPToolInputSchema(
            type: type,
            properties: properties,
            required: required,
            additionalProperties: additionalProperties
        )
    }
    
    /// Call a tool on the server
    public func callTool(name: String, arguments: [String: AnyCodableValue]) async throws -> MCPCallToolResult {
        let params: [String: AnyCodableValue] = [
            "name": .string(name),
            "arguments": .object(arguments)
        ]
        
        let response = try await sendRequest(method: "tools/call", params: params)
        
        if let error = response.error {
            throw MCPClientError.serverError(error)
        }
        
        guard let result = response.result else {
            throw MCPClientError.invalidResponse("No result in tools/call response")
        }
        
        return try decodeCallToolResult(from: result)
    }
    
    private func decodeCallToolResult(from value: AnyCodableValue) throws -> MCPCallToolResult {
        guard case .object(let dict) = value else {
            throw MCPClientError.invalidResponse("Invalid tools/call result format")
        }
        
        var content: [MCPToolContent] = []
        if case .array(let contentArray) = dict["content"] {
            content = contentArray.compactMap { decodeToolContent(from: $0) }
        }
        
        var isError: Bool?
        if case .bool(let v) = dict["isError"] {
            isError = v
        }
        
        return MCPCallToolResult(content: content, isError: isError)
    }
    
    private func decodeToolContent(from value: AnyCodableValue) -> MCPToolContent? {
        guard case .object(let dict) = value,
              case .string(let type) = dict["type"] else {
            return nil
        }
        
        var text: String?
        if case .string(let t) = dict["text"] {
            text = t
        }
        
        var mimeType: String?
        if case .string(let m) = dict["mimeType"] {
            mimeType = m
        }
        
        var data: String?
        if case .string(let d) = dict["data"] {
            data = d
        }
        
        return MCPToolContent(type: type, text: text, mimeType: mimeType, data: data)
    }
    
    /// Invalidate the tools cache (call when server notifies of changes)
    public func invalidateToolsCache() {
        cachedTools = nil
    }
    
    // MARK: - Request Helpers
    
    private func sendRequest(method: String, params: [String: AnyCodableValue]?) async throws -> MCPResponse {
        logger.info("sendRequest: method=\(method)")
        requestId += 1
        logger.info("sendRequest: requestId=\(self.requestId)")
        let request = MCPRequest(id: requestId, method: method, params: params)
        logger.info("sendRequest: Request created, calling transport.send()")
        let response = try await transport.send(request)
        logger.info("sendRequest: Got response")
        return response
    }
    
    private func sendNotification(method: String, params: [String: AnyCodableValue]?) async throws {
        // Notifications don't have an id and don't expect a response
        // We'll send it as a request but ignore the response
        requestId += 1
        let request = MCPRequest(id: requestId, method: method, params: params)
        _ = try? await transport.send(request)
    }
}
