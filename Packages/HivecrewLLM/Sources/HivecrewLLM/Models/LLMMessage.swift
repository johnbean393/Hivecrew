//
//  LLMMessage.swift
//  HivecrewLLM
//
//  Abstraction for chat messages sent to/from LLMs
//

import Foundation

/// Role of a message in the conversation
public enum LLMMessageRole: String, Sendable, Codable {
    case system
    case user
    case assistant
    case tool
}

/// Content types that can be included in a message
public enum LLMMessageContent: Sendable, Codable, Equatable {
    /// Plain text content
    case text(String)
    
    /// Image content with base64-encoded data and MIME type
    case imageBase64(data: String, mimeType: String)
    
    /// Image content from a URL
    case imageURL(URL)
    
    /// Tool result content
    case toolResult(toolCallId: String, content: String)
}

/// A message in the conversation with an LLM
public struct LLMMessage: Sendable, Codable, Equatable {
    /// Role of the sender
    public let role: LLMMessageRole
    
    /// Content of the message (can be multiple parts for vision)
    public let content: [LLMMessageContent]
    
    /// Optional name for the message sender
    public let name: String?
    
    /// Tool calls made by the assistant (only for assistant messages)
    public let toolCalls: [LLMToolCall]?
    
    /// Tool call ID this message is responding to (only for tool messages)
    public let toolCallId: String?
    
    // MARK: - Convenience Initializers
    
    /// Create a system message
    public static func system(_ text: String) -> LLMMessage {
        LLMMessage(role: .system, content: [.text(text)], name: nil, toolCalls: nil, toolCallId: nil)
    }
    
    /// Create a user message with text only
    public static func user(_ text: String) -> LLMMessage {
        LLMMessage(role: .user, content: [.text(text)], name: nil, toolCalls: nil, toolCallId: nil)
    }
    
    /// Create a user message with text and images
    public static func user(text: String, images: [LLMMessageContent]) -> LLMMessage {
        var content: [LLMMessageContent] = [.text(text)]
        content.append(contentsOf: images)
        return LLMMessage(role: .user, content: content, name: nil, toolCalls: nil, toolCallId: nil)
    }
    
    /// Create an assistant message
    public static func assistant(_ text: String, toolCalls: [LLMToolCall]? = nil) -> LLMMessage {
        LLMMessage(role: .assistant, content: [.text(text)], name: nil, toolCalls: toolCalls, toolCallId: nil)
    }
    
    /// Create a tool result message
    public static func toolResult(toolCallId: String, content: String) -> LLMMessage {
        LLMMessage(
            role: .tool,
            content: [.toolResult(toolCallId: toolCallId, content: content)],
            name: nil,
            toolCalls: nil,
            toolCallId: toolCallId
        )
    }
    
    public init(
        role: LLMMessageRole,
        content: [LLMMessageContent],
        name: String? = nil,
        toolCalls: [LLMToolCall]? = nil,
        toolCallId: String? = nil
    ) {
        self.role = role
        self.content = content
        self.name = name
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
    }
    
    /// Get the text content of the message (concatenates all text parts)
    public var textContent: String {
        content.compactMap { part in
            if case .text(let text) = part {
                return text
            }
            return nil
        }.joined(separator: "\n")
    }
    
    /// Check if the message contains any image content
    public var hasImages: Bool {
        content.contains { part in
            switch part {
            case .imageBase64, .imageURL:
                return true
            default:
                return false
            }
        }
    }
}
