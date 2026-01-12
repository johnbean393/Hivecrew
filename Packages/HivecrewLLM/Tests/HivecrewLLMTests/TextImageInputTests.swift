//
//  TextImageInputTests.swift
//  HivecrewLLMTests
//
//  Tests for text and image input handling in LLM messages
//

import XCTest
@testable import HivecrewLLM

final class TextImageInputTests: XCTestCase {
    
    // MARK: - Message Creation Tests
    
    func testCreateTextOnlyMessage() {
        let message = LLMMessage.user("Hello, world!")
        
        XCTAssertEqual(message.role, .user)
        XCTAssertEqual(message.content.count, 1)
        XCTAssertEqual(message.textContent, "Hello, world!")
        XCTAssertNil(message.toolCalls)
        XCTAssertNil(message.toolCallId)
    }
    
    func testCreateSystemMessage() {
        let message = LLMMessage.system("You are a helpful assistant.")
        
        XCTAssertEqual(message.role, .system)
        XCTAssertEqual(message.textContent, "You are a helpful assistant.")
    }
    
    func testCreateAssistantMessage() {
        let message = LLMMessage.assistant("I can help you with that.")
        
        XCTAssertEqual(message.role, .assistant)
        XCTAssertEqual(message.textContent, "I can help you with that.")
    }
    
    func testCreateUserMessageWithBase64Image() {
        let imageData = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        let message = LLMMessage.user(
            text: "What is in this image?",
            images: [.imageBase64(data: imageData, mimeType: "image/png")]
        )
        
        XCTAssertEqual(message.role, .user)
        XCTAssertEqual(message.content.count, 2)
        
        // First content should be text
        if case .text(let text) = message.content[0] {
            XCTAssertEqual(text, "What is in this image?")
        } else {
            XCTFail("First content should be text")
        }
        
        // Second content should be image
        if case .imageBase64(let data, let mimeType) = message.content[1] {
            XCTAssertEqual(data, imageData)
            XCTAssertEqual(mimeType, "image/png")
        } else {
            XCTFail("Second content should be base64 image")
        }
    }
    
    func testCreateUserMessageWithImageURL() {
        let imageURL = URL(string: "https://example.com/image.png")!
        let message = LLMMessage.user(
            text: "Describe this image",
            images: [.imageURL(imageURL)]
        )
        
        XCTAssertEqual(message.role, .user)
        XCTAssertEqual(message.content.count, 2)
        
        if case .imageURL(let url) = message.content[1] {
            XCTAssertEqual(url, imageURL)
        } else {
            XCTFail("Second content should be image URL")
        }
    }
    
    func testCreateUserMessageWithMultipleImages() {
        let imageData1 = "base64data1"
        let imageData2 = "base64data2"
        let message = LLMMessage.user(
            text: "Compare these images",
            images: [
                .imageBase64(data: imageData1, mimeType: "image/png"),
                .imageBase64(data: imageData2, mimeType: "image/jpeg")
            ]
        )
        
        XCTAssertEqual(message.content.count, 3)
        
        if case .imageBase64(let data, let mimeType) = message.content[1] {
            XCTAssertEqual(data, imageData1)
            XCTAssertEqual(mimeType, "image/png")
        } else {
            XCTFail("Second content should be first image")
        }
        
        if case .imageBase64(let data, let mimeType) = message.content[2] {
            XCTAssertEqual(data, imageData2)
            XCTAssertEqual(mimeType, "image/jpeg")
        } else {
            XCTFail("Third content should be second image")
        }
    }
    
    // MARK: - Message Content Tests
    
    func testTextContentConcatenation() {
        let message = LLMMessage(
            role: .user,
            content: [
                .text("Hello"),
                .text("World")
            ]
        )
        
        XCTAssertEqual(message.textContent, "Hello\nWorld")
    }
    
    func testTextContentIgnoresImages() {
        let message = LLMMessage.user(
            text: "Analyze this",
            images: [.imageBase64(data: "data", mimeType: "image/png")]
        )
        
        XCTAssertEqual(message.textContent, "Analyze this")
    }
    
    // MARK: - Encoding/Decoding Tests
    
    func testMessageEncodingDecoding() throws {
        let originalMessage = LLMMessage.user(
            text: "What's in this image?",
            images: [.imageBase64(data: "testdata", mimeType: "image/png")]
        )
        
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        let data = try encoder.encode(originalMessage)
        let decodedMessage = try decoder.decode(LLMMessage.self, from: data)
        
        XCTAssertEqual(decodedMessage.role, originalMessage.role)
        XCTAssertEqual(decodedMessage.content.count, originalMessage.content.count)
        XCTAssertEqual(decodedMessage.textContent, originalMessage.textContent)
    }
    
    // MARK: - Configuration Tests
    
    func testLLMConfigurationCreation() {
        let config = LLMConfiguration(
            displayName: "Test Provider",
            apiKey: "test-key",
            model: "gpt-5.2"
        )
        
        XCTAssertEqual(config.displayName, "Test Provider")
        XCTAssertEqual(config.apiKey, "test-key")
        XCTAssertEqual(config.model, "gpt-5.2")
        XCTAssertNil(config.baseURL)
        XCTAssertNil(config.organizationId)
        XCTAssertEqual(config.timeoutInterval, LLMConfiguration.defaultTimeout)
    }
    
    func testLLMConfigurationWithCustomBaseURL() {
        let customURL = URL(string: "https://custom.api.com/v1")!
        let config = LLMConfiguration(
            displayName: "Custom Provider",
            baseURL: customURL,
            apiKey: "custom-key",
            model: "custom-model"
        )
        
        XCTAssertEqual(config.baseURL, customURL)
        XCTAssertEqual(config.host, "custom.api.com")
        XCTAssertEqual(config.scheme, "https")
        XCTAssertEqual(config.basePath, "/v1")
    }
    
    // MARK: - Response Tests
    
    func testLLMResponseConvenienceAccessors() {
        let message = LLMMessage.assistant("Test response")
        let choice = LLMResponseChoice(index: 0, message: message, finishReason: .stop)
        let usage = LLMUsage(promptTokens: 10, completionTokens: 20, totalTokens: 30)
        
        let response = LLMResponse(
            id: "test-id",
            model: "gpt-5.2",
            created: Date(),
            choices: [choice],
            usage: usage
        )
        
        XCTAssertEqual(response.text, "Test response")
        XCTAssertEqual(response.finishReason, .stop)
        XCTAssertFalse(response.hasToolCalls)
        XCTAssertEqual(response.usage?.totalTokens, 30)
    }
}
