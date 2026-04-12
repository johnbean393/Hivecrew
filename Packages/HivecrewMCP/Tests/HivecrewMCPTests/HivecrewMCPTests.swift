//
//  HivecrewMCPTests.swift
//  HivecrewMCPTests
//
//  Tests for the HivecrewMCP package
//

import Foundation
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

@Suite("Login Shell Environment Tests")
struct LoginShellEnvironmentTests {

    @Test("Shell environment output is parsed between markers")
    func testParseShellEnvironmentOutput() throws {
        let output = """
        preface noise
        \(LoginShellEnvironmentSnapshot.startMarker)
        {"PATH":"/opt/homebrew/bin:/usr/bin","OPENAI_API_KEY":"test-key"}
        \(LoginShellEnvironmentSnapshot.endMarker)
        trailing noise
        """

        let environment = try LoginShellEnvironmentSnapshot.parse(output: output)

        #expect(environment["PATH"] == "/opt/homebrew/bin:/usr/bin")
        #expect(environment["OPENAI_API_KEY"] == "test-key")
    }

    @Test("Explicit overrides win over shell and base environments")
    func testEnvironmentMergePrecedence() {
        let merged = LoginShellEnvironmentSnapshot.merge(
            base: [
                "PATH": "/usr/bin",
                "FROM_BASE": "1",
                "SHARED": "base"
            ],
            shell: [
                "PATH": "/opt/homebrew/bin:/usr/bin",
                "FROM_SHELL": "1",
                "SHARED": "shell"
            ],
            overrides: [
                "FROM_OVERRIDE": "1",
                "SHARED": "override"
            ]
        )

        #expect(merged["PATH"] == "/opt/homebrew/bin:/usr/bin")
        #expect(merged["FROM_BASE"] == "1")
        #expect(merged["FROM_SHELL"] == "1")
        #expect(merged["FROM_OVERRIDE"] == "1")
        #expect(merged["SHARED"] == "override")
    }
}
