//
//  HivecrewMCPTests.swift
//  HivecrewMCPTests
//
//  Tests for the HivecrewMCP package
//

import Testing
@testable import HivecrewMCP

@Suite("MCP Types Tests")
struct MCPTypesTests {
    
    @Test("AnyCodableValue encodes and decodes primitives")
    func testAnyCodableValuePrimitives() throws {
        let values: [AnyCodableValue] = [
            .null,
            .bool(true),
            .int(42),
            .double(3.14),
            .string("hello")
        ]
        
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        for value in values {
            let data = try encoder.encode(value)
            let decoded = try decoder.decode(AnyCodableValue.self, from: data)
            #expect(decoded == value)
        }
    }
    
    @Test("AnyCodableValue encodes and decodes arrays")
    func testAnyCodableValueArrays() throws {
        let value = AnyCodableValue.array([.int(1), .string("two"), .bool(false)])
        
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(AnyCodableValue.self, from: data)
        
        #expect(decoded == value)
    }
    
    @Test("AnyCodableValue encodes and decodes objects")
    func testAnyCodableValueObjects() throws {
        let value = AnyCodableValue.object([
            "name": .string("test"),
            "count": .int(5),
            "active": .bool(true)
        ])
        
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(AnyCodableValue.self, from: data)
        
        #expect(decoded == value)
    }
    
    @Test("MCPRequest encodes correctly")
    func testMCPRequestEncoding() throws {
        let request = MCPRequest(
            id: 1,
            method: "tools/list",
            params: nil
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        
        #expect(json?["jsonrpc"] as? String == "2.0")
        #expect(json?["id"] as? Int == 1)
        #expect(json?["method"] as? String == "tools/list")
    }
    
    @Test("MCPTool input schema converts to dictionary")
    func testToolInputSchemaToDictionary() {
        let schema = MCPToolInputSchema(
            type: "object",
            properties: [
                "path": .object([
                    "type": .string("string"),
                    "description": .string("File path")
                ])
            ],
            required: ["path"],
            additionalProperties: false
        )
        
        let dict = schema.toDictionary()
        
        #expect(dict["type"] as? String == "object")
        #expect(dict["required"] as? [String] == ["path"])
        #expect(dict["additionalProperties"] as? Bool == false)
    }
    
    @Test("MCPServerConfig initializes correctly")
    func testServerConfigInit() {
        let config = MCPServerConfig(
            name: "Test Server",
            transportType: .stdio,
            command: "npx",
            arguments: ["-y", "@modelcontextprotocol/server-filesystem"]
        )
        
        #expect(config.name == "Test Server")
        #expect(config.transportType == .stdio)
        #expect(config.command == "npx")
        #expect(config.arguments == ["-y", "@modelcontextprotocol/server-filesystem"])
    }
}

@Suite("MCP Tool Prefix Tests")
struct MCPToolPrefixTests {
    
    @Test("Tool name prefixing works correctly")
    func testToolNamePrefixing() async {
        let config = MCPServerConfig(
            name: "File System",
            transportType: .stdio,
            command: "npx"
        )
        
        let connection = MCPServerConnection(config: config)
        let prefixed = await connection.prefixedToolName("read_file")
        
        #expect(prefixed == "mcp_file_system_read_file")
    }
    
    @Test("Tool ownership detection works")
    func testToolOwnership() async {
        let config = MCPServerConfig(
            name: "GitHub",
            transportType: .stdio,
            command: "npx"
        )
        
        let connection = MCPServerConnection(config: config)
        
        let owns = await connection.ownsToolName("mcp_github_create_issue")
        let doesNotOwn = await connection.ownsToolName("mcp_filesystem_read_file")
        
        #expect(owns == true)
        #expect(doesNotOwn == false)
    }
    
    @Test("Tool name extraction works")
    func testToolNameExtraction() async {
        let config = MCPServerConfig(
            name: "GitHub",
            transportType: .stdio,
            command: "npx"
        )
        
        let connection = MCPServerConnection(config: config)
        let extracted = await connection.extractToolName(from: "mcp_github_create_issue")
        
        #expect(extracted == "create_issue")
    }
}
