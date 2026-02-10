//
//  ToolCallingTests.swift
//  HivecrewLLMTests
//
//  Tests for tool/function calling support
//

import XCTest
@testable import HivecrewLLM
import HivecrewAgentProtocol

final class ToolCallingTests: XCTestCase {
    
    var toolSchemaBuilder: ToolSchemaBuilder!
    
    override func setUp() {
        super.setUp()
        toolSchemaBuilder = ToolSchemaBuilder()
    }
    
    // MARK: - Tool Schema Builder Tests
    
    func testBuildToolsForSubset() {
        let methods: [AgentMethod] = [.screenshot, .mouseClick, .keyboardType]
        let tools = toolSchemaBuilder.buildTools(for: methods)
        
        XCTAssertEqual(tools.count, 3)
        
        let toolNames = tools.map { $0.function.name }
        XCTAssertTrue(toolNames.contains("screenshot"))
        XCTAssertTrue(toolNames.contains("mouse_click"))
        XCTAssertTrue(toolNames.contains("keyboard_type"))
    }
    
    func testScreenshotToolDefinition() {
        let tool = toolSchemaBuilder.buildToolDefinition(for: .screenshot)
        
        XCTAssertEqual(tool.type, "function")
        XCTAssertEqual(tool.function.name, "screenshot")
        XCTAssertTrue(tool.function.description.contains("screenshot"))
        
        // Screenshot has no required parameters
        let params = tool.function.parameters
        XCTAssertEqual(params["type"] as? String, "object")
        XCTAssertFalse(params["additionalProperties"] as? Bool ?? true)
    }
    
    func testMouseClickToolDefinition() {
        let tool = toolSchemaBuilder.buildToolDefinition(for: .mouseClick)
        
        XCTAssertEqual(tool.function.name, "mouse_click")
        
        let params = tool.function.parameters
        let properties = params["properties"] as? [String: Any]
        let required = params["required"] as? [String]
        
        XCTAssertNotNil(properties)
        XCTAssertNotNil(required)
        
        // Should have x, y, button, clickType properties
        XCTAssertNotNil(properties?["x"])
        XCTAssertNotNil(properties?["y"])
        XCTAssertNotNil(properties?["button"])
        XCTAssertNotNil(properties?["clickType"])
        
        // x and y should be required
        XCTAssertTrue(required?.contains("x") ?? false)
        XCTAssertTrue(required?.contains("y") ?? false)
    }
    
    func testKeyboardTypeToolDefinition() {
        let tool = toolSchemaBuilder.buildToolDefinition(for: .keyboardType)
        
        XCTAssertEqual(tool.function.name, "keyboard_type")
        
        let params = tool.function.parameters
        let properties = params["properties"] as? [String: Any]
        let required = params["required"] as? [String]
        
        // Should have text property
        XCTAssertNotNil(properties?["text"])
        
        // text should be required
        XCTAssertTrue(required?.contains("text") ?? false)
    }
    
    func testRunShellToolDefinition() {
        let tool = toolSchemaBuilder.buildToolDefinition(for: .runShell)
        
        XCTAssertEqual(tool.function.name, "run_shell")
        
        let params = tool.function.parameters
        let properties = params["properties"] as? [String: Any]
        let required = params["required"] as? [String]
        
        // Should have command and timeout properties
        XCTAssertNotNil(properties?["command"])
        XCTAssertNotNil(properties?["timeout"])
        
        // Only command should be required
        XCTAssertTrue(required?.contains("command") ?? false)
        XCTAssertFalse(required?.contains("timeout") ?? true)
    }
    
    // MARK: - Tool Call Parsing Tests
    
    func testParseToolCallArguments() throws {
        let toolCall = LLMToolCall(
            id: "call_123",
            function: LLMFunctionCall(
                name: "mouse_click",
                arguments: #"{"x": 100.5, "y": 200.5, "button": "left"}"#
            )
        )
        
        let args = try toolCall.function.argumentsDictionary()
        
        XCTAssertEqual(args["x"] as? Double, 100.5)
        XCTAssertEqual(args["y"] as? Double, 200.5)
        XCTAssertEqual(args["button"] as? String, "left")
    }
    
    func testDecodeToolCallToStruct() throws {
        let toolCall = LLMToolCall(
            id: "call_456",
            function: LLMFunctionCall(
                name: "keyboard_type",
                arguments: #"{"text": "Hello, World!"}"#
            )
        )
        
        let params = try toolCall.function.decodeArguments(KeyboardTypeParams.self)
        
        XCTAssertEqual(params.text, "Hello, World!")
    }
    
    func testDecodeMouseClickParams() throws {
        let toolCall = LLMToolCall(
            id: "call_789",
            function: LLMFunctionCall(
                name: "mouse_click",
                arguments: #"{"x": 50.0, "y": 75.0, "button": "right", "clickType": "double"}"#
            )
        )
        
        let params = try toolCall.function.decodeArguments(MouseClickParams.self)
        
        XCTAssertEqual(params.x, 50.0)
        XCTAssertEqual(params.y, 75.0)
        XCTAssertEqual(params.button, .right)
        XCTAssertEqual(params.clickType, .double)
    }
    
    func testParseInvalidArgumentsThrows() {
        let toolCall = LLMToolCall(
            id: "call_invalid",
            function: LLMFunctionCall(
                name: "test",
                arguments: "not valid json"
            )
        )
        
        XCTAssertThrowsError(try toolCall.function.argumentsDictionary()) { error in
            // The error should be either LLMError.invalidToolArguments or a JSONSerialization error
            // Both indicate the arguments couldn't be parsed
            let isExpectedError = (error is LLMError) || (error is DecodingError) || (error is NSError)
            XCTAssertTrue(isExpectedError, "Expected a parsing error, got: \(error)")
        }
    }
    
    func testParseEmptyArgumentsReturnsEmptyDictionary() throws {
        // Test empty string (common when LLM calls tools with no required params)
        let toolCall1 = LLMToolCall(
            id: "call_empty",
            function: LLMFunctionCall(
                name: "get_login_credentials",
                arguments: ""
            )
        )
        
        let args1 = try toolCall1.function.argumentsDictionary()
        XCTAssertTrue(args1.isEmpty)
        
        // Test whitespace-only string
        let toolCall2 = LLMToolCall(
            id: "call_whitespace",
            function: LLMFunctionCall(
                name: "get_location",
                arguments: "   \n  "
            )
        )
        
        let args2 = try toolCall2.function.argumentsDictionary()
        XCTAssertTrue(args2.isEmpty)
        
        // Test empty JSON object still works
        let toolCall3 = LLMToolCall(
            id: "call_empty_obj",
            function: LLMFunctionCall(
                name: "screenshot",
                arguments: "{}"
            )
        )
        
        let args3 = try toolCall3.function.argumentsDictionary()
        XCTAssertTrue(args3.isEmpty)
    }
    
    // MARK: - Tool Result Message Tests
    
    func testCreateToolResultMessage() {
        let message = LLMMessage.toolResult(
            toolCallId: "call_123",
            content: #"{"success": true, "output": "Command executed"}"#
        )
        
        XCTAssertEqual(message.role, .tool)
        XCTAssertEqual(message.toolCallId, "call_123")
        
        if case .toolResult(let id, let content) = message.content[0] {
            XCTAssertEqual(id, "call_123")
            XCTAssertTrue(content.contains("success"))
        } else {
            XCTFail("Expected tool result content")
        }
    }
    
    // MARK: - Response with Tool Calls Tests
    
    func testResponseWithToolCalls() {
        let toolCalls = [
            LLMToolCall(
                id: "call_1",
                function: LLMFunctionCall(name: "screenshot", arguments: "{}")
            ),
            LLMToolCall(
                id: "call_2",
                function: LLMFunctionCall(
                    name: "mouse_click",
                    arguments: #"{"x": 100, "y": 200}"#
                )
            )
        ]
        
        let message = LLMMessage.assistant("", toolCalls: toolCalls)
        let choice = LLMResponseChoice(index: 0, message: message, finishReason: .toolCalls)
        
        let response = LLMResponse(
            id: "resp_123",
            model: "moonshotai/kimi-k2.5",
            created: Date(),
            choices: [choice],
            usage: nil
        )
        
        XCTAssertTrue(response.hasToolCalls)
        XCTAssertEqual(response.toolCalls?.count, 2)
        XCTAssertEqual(response.finishReason, .toolCalls)
        
        XCTAssertEqual(response.toolCalls?[0].function.name, "screenshot")
        XCTAssertEqual(response.toolCalls?[1].function.name, "mouse_click")
    }
    
    // MARK: - LLMToolDefinition Tests
    
    func testToolDefinitionEquality() {
        let tool1 = LLMToolDefinition.function(
            name: "test_tool",
            description: "A test tool",
            parameters: ["type": "object", "properties": [:] as [String: Any]]
        )
        
        let tool2 = LLMToolDefinition.function(
            name: "test_tool",
            description: "A test tool",
            parameters: ["type": "object", "properties": [:] as [String: Any]]
        )
        
        XCTAssertEqual(tool1, tool2)
    }
    
    func testToolDefinitionEncodingDecoding() throws {
        let original = LLMToolDefinition.function(
            name: "test_func",
            description: "Test function",
            parameters: [
                "type": "object",
                "properties": [
                    "arg1": ["type": "string", "description": "First argument"]
                ] as [String : Any],
                "required": ["arg1"]
            ]
        )
        
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(LLMToolDefinition.self, from: data)
        
        XCTAssertEqual(decoded.type, original.type)
        XCTAssertEqual(decoded.function.name, original.function.name)
        XCTAssertEqual(decoded.function.description, original.function.description)
    }
    
    // MARK: - LLM Service Tests
    
    func testLLMServiceCreateClient() {
        let service = LLMService()
        
        let client = service.createClient(
            apiKey: "test-key",
            model: "moonshotai/kimi-k2.5"
        )
        
        XCTAssertEqual(client.configuration.apiKey, "test-key")
        XCTAssertEqual(client.configuration.model, "moonshotai/kimi-k2.5")
        XCTAssertNil(client.configuration.baseURL)
    }
    
    func testLLMServiceCreateClientWithCustomURL() {
        let service = LLMService()
        let customURL = URL(string: "https://custom.api.com")!
        
        let client = service.createClient(
            apiKey: "custom-key",
            model: "custom-model",
            baseURL: customURL
        )
        
        XCTAssertEqual(client.configuration.baseURL, customURL)
    }
    
}
