//
//  LLMResponse.swift
//  HivecrewLLM
//
//  Response from an LLM API call
//

import Foundation

/// Reason why the model stopped generating
public enum LLMFinishReason: String, Sendable, Codable {
    case stop
    case length
    case toolCalls = "tool_calls"
    case contentFilter = "content_filter"
    case unknown
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = LLMFinishReason(rawValue: rawValue) ?? .unknown
    }
}

/// Token usage information
public struct LLMUsage: Sendable, Codable, Equatable {
    /// Number of tokens in the prompt
    public let promptTokens: Int
    
    /// Number of tokens in the completion
    public let completionTokens: Int
    
    /// Total tokens used
    public let totalTokens: Int
    
    public init(promptTokens: Int, completionTokens: Int, totalTokens: Int) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
    }
}

/// A choice in the response (models can return multiple choices)
public struct LLMResponseChoice: Sendable, Codable, Equatable {
    /// Index of this choice
    public let index: Int
    
    /// The message content
    public let message: LLMMessage
    
    /// Reason the model stopped generating
    public let finishReason: LLMFinishReason?
    
    public init(index: Int, message: LLMMessage, finishReason: LLMFinishReason?) {
        self.index = index
        self.message = message
        self.finishReason = finishReason
    }
}

/// Complete response from an LLM API call
public struct LLMResponse: Sendable, Codable, Equatable {
    /// Unique ID for this response
    public let id: String
    
    /// Model that generated the response
    public let model: String
    
    /// Timestamp when the response was created
    public let created: Date
    
    /// Available choices (usually just one)
    public let choices: [LLMResponseChoice]
    
    /// Token usage information
    public let usage: LLMUsage?
    
    public init(
        id: String,
        model: String,
        created: Date,
        choices: [LLMResponseChoice],
        usage: LLMUsage?
    ) {
        self.id = id
        self.model = model
        self.created = created
        self.choices = choices
        self.usage = usage
    }
    
    /// Convenience accessor for the first choice's message
    public var message: LLMMessage? {
        choices.first?.message
    }
    
    /// Convenience accessor for the first choice's text content
    public var text: String? {
        message?.textContent
    }
    
    /// Convenience accessor for tool calls from the first choice
    public var toolCalls: [LLMToolCall]? {
        message?.toolCalls
    }
    
    /// Check if the response contains tool calls
    public var hasToolCalls: Bool {
        guard let toolCalls = toolCalls else { return false }
        return !toolCalls.isEmpty
    }
    
    /// Convenience accessor for the finish reason
    public var finishReason: LLMFinishReason? {
        choices.first?.finishReason
    }
    
    /// Convenience accessor for reasoning content from the first choice
    public var reasoning: String? {
        message?.reasoning
    }
}
