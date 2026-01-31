//
//  LLMClientProtocol.swift
//  HivecrewLLM
//
//  Protocol defining the interface for LLM clients
//

import Foundation

/// Callback for streaming reasoning updates
public typealias ReasoningStreamCallback = @Sendable (String) -> Void

/// Callback for streaming content updates
public typealias ContentStreamCallback = @Sendable (String) -> Void

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
    
    /// Send a chat completion request with streaming callbacks
    ///
    /// - Parameters:
    ///   - messages: The conversation messages
    ///   - tools: Optional tool definitions for function calling
    ///   - onReasoningUpdate: Callback invoked with accumulated reasoning text as it streams
    ///   - onContentUpdate: Callback invoked with accumulated content text as it streams
    /// - Returns: The LLM response
    /// - Throws: LLMError if the request fails
    func chatWithStreaming(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        onReasoningUpdate: ReasoningStreamCallback?,
        onContentUpdate: ContentStreamCallback?
    ) async throws -> LLMResponse
    
    /// Send a chat completion request with streaming reasoning callback (legacy)
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
    public func chatWithStreaming(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        onReasoningUpdate: ReasoningStreamCallback?,
        onContentUpdate: ContentStreamCallback?
    ) async throws -> LLMResponse {
        // Default: just call non-streaming version
        let response = try await chat(messages: messages, tools: tools)
        // If there's reasoning in the response, send it all at once
        if let reasoning = response.reasoning, let callback = onReasoningUpdate {
            callback(reasoning)
        }
        // If there's content in the response, send it all at once
        if let text = response.text, let callback = onContentUpdate {
            callback(text)
        }
        return response
    }
    
    /// Legacy streaming method - calls new method without content callback
    public func chatWithReasoningStream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        onReasoningUpdate: ReasoningStreamCallback?
    ) async throws -> LLMResponse {
        try await chatWithStreaming(
            messages: messages,
            tools: tools,
            onReasoningUpdate: onReasoningUpdate,
            onContentUpdate: nil
        )
    }
    
    /// Default implementation returns empty list (providers can override)
    public func listModels() async throws -> [String] {
        return []
    }
}
