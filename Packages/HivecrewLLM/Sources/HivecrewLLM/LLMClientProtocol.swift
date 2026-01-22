//
//  LLMClientProtocol.swift
//  HivecrewLLM
//
//  Protocol defining the interface for LLM clients
//

import Foundation

/// Callback for streaming reasoning updates
public typealias ReasoningStreamCallback = @Sendable (String) -> Void

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
    /// - Returns: The LLM response
    /// - Throws: LLMError if the request fails
    func chat(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?
    ) async throws -> LLMResponse
    
    /// Send a chat completion request with streaming reasoning callback
    ///
    /// - Parameters:
    ///   - messages: The conversation messages
    ///   - tools: Optional tool definitions for function calling
    ///   - onReasoningUpdate: Callback invoked with accumulated reasoning text as it streams
    /// - Returns: The LLM response
    /// - Throws: LLMError if the request fails
    func chatWithReasoningStream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        onReasoningUpdate: ReasoningStreamCallback?
    ) async throws -> LLMResponse
    
    /// Test the connection to the LLM provider
    ///
    /// - Returns: True if the connection is successful
    /// - Throws: LLMError if the connection fails
    func testConnection() async throws -> Bool
    
    /// List available models from the provider
    ///
    /// - Returns: List of model IDs
    /// - Throws: LLMError if the request fails
    func listModels() async throws -> [String]
}

// MARK: - Default Implementations

extension LLMClientProtocol {
    /// Simple chat with just messages
    public func chat(messages: [LLMMessage]) async throws -> LLMResponse {
        try await chat(messages: messages, tools: nil)
    }
    
    /// Default implementation of streaming chat falls back to non-streaming
    public func chatWithReasoningStream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        onReasoningUpdate: ReasoningStreamCallback?
    ) async throws -> LLMResponse {
        // Default: just call non-streaming version
        let response = try await chat(messages: messages, tools: tools)
        // If there's reasoning in the response, send it all at once
        if let reasoning = response.reasoning, let callback = onReasoningUpdate {
            callback(reasoning)
        }
        return response
    }
    
    /// Default implementation returns empty list (providers can override)
    public func listModels() async throws -> [String] {
        return []
    }
}
