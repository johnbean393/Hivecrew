//
//  LLMClientProtocol.swift
//  HivecrewLLM
//
//  Protocol defining the interface for LLM clients
//

import Foundation

/// Protocol for LLM client implementations
///
/// This protocol provides an abstraction layer for different LLM providers,
/// allowing the agent system to work with various backends (OpenAI, Azure, local models, etc.)
public protocol LLMClientProtocol: Sendable {
    /// The configuration used by this client
    var configuration: LLMConfiguration { get }
    
    /// Send a chat completion request
    ///
    /// - Parameters:
    ///   - messages: The conversation messages
    ///   - tools: Optional tool definitions for function calling
    ///   - temperature: Optional temperature for response randomness (0.0 - 2.0)
    ///   - maxTokens: Optional maximum tokens in the response
    /// - Returns: The LLM response
    /// - Throws: LLMError if the request fails
    func chat(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        temperature: Double?,
        maxTokens: Int?
    ) async throws -> LLMResponse
    
    /// Test the connection to the LLM provider
    ///
    /// - Returns: True if the connection is successful
    /// - Throws: LLMError if the connection fails
    func testConnection() async throws -> Bool
}

// MARK: - Default Implementations

extension LLMClientProtocol {
    /// Send a chat completion request with default parameters
    public func chat(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]? = nil,
        temperature: Double? = nil,
        maxTokens: Int? = nil
    ) async throws -> LLMResponse {
        try await chat(messages: messages, tools: tools, temperature: temperature, maxTokens: maxTokens)
    }
    
    /// Simple chat with just messages
    public func chat(messages: [LLMMessage]) async throws -> LLMResponse {
        try await chat(messages: messages, tools: nil, temperature: nil, maxTokens: nil)
    }
}
