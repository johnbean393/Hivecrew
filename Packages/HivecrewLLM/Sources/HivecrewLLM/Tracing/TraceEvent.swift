//
//  TraceEvent.swift
//  HivecrewLLM
//
//  Types for agent execution tracing
//

import Foundation

/// Type of trace event
public enum TraceEventType: String, Sendable, Codable {
    /// Session started
    case sessionStart = "session_start"
    
    /// Session ended
    case sessionEnd = "session_end"
    
    /// Observation taken (screenshot, etc.)
    case observation = "observation"
    
    /// LLM request sent
    case llmRequest = "llm_request"
    
    /// LLM response received
    case llmResponse = "llm_response"
    
    /// Tool call executed
    case toolCall = "tool_call"
    
    /// Tool result received
    case toolResult = "tool_result"
    
    /// User intervention
    case userIntervention = "user_intervention"
    
    /// Error occurred
    case error = "error"
    
    /// Custom event
    case custom = "custom"
}

/// A single event in the agent execution trace
public struct TraceEvent: Sendable, Codable {
    /// Unique identifier for this event
    public let id: String
    
    /// Session ID this event belongs to
    public let sessionId: String
    
    /// Type of event
    public let type: TraceEventType
    
    /// Timestamp when the event occurred
    public let timestamp: Date
    
    /// Step number in the session (0-indexed)
    public let step: Int
    
    /// Event-specific data
    public let data: TraceEventData
    
    /// Optional duration in milliseconds (for timed events)
    public let durationMs: Int?
    
    public init(
        id: String = UUID().uuidString,
        sessionId: String,
        type: TraceEventType,
        timestamp: Date = Date(),
        step: Int,
        data: TraceEventData,
        durationMs: Int? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.type = type
        self.timestamp = timestamp
        self.step = step
        self.data = data
        self.durationMs = durationMs
    }
}

/// Event-specific data payload
public enum TraceEventData: Sendable, Codable {
    /// Session start data
    case sessionStart(SessionStartData)
    
    /// Session end data
    case sessionEnd(SessionEndData)
    
    /// Observation data
    case observation(ObservationData)
    
    /// LLM request data
    case llmRequest(LLMRequestData)
    
    /// LLM response data
    case llmResponse(LLMResponseData)
    
    /// Tool call data
    case toolCall(ToolCallData)
    
    /// Tool result data
    case toolResult(ToolResultData)
    
    /// User intervention data
    case userIntervention(UserInterventionData)
    
    /// Error data
    case error(ErrorData)
    
    /// Custom event data
    case custom([String: String])
}

// MARK: - Event Data Types

public struct SessionStartData: Sendable, Codable {
    public let taskId: String
    public let taskDescription: String
    public let model: String
    public let vmId: String?
    
    public init(taskId: String, taskDescription: String, model: String, vmId: String?) {
        self.taskId = taskId
        self.taskDescription = taskDescription
        self.model = model
        self.vmId = vmId
    }
}

public struct SessionEndData: Sendable, Codable {
    public let status: String
    public let totalSteps: Int
    public let totalTokens: Int
    public let estimatedCost: Double?
    public let summary: String?
    
    public init(status: String, totalSteps: Int, totalTokens: Int, estimatedCost: Double?, summary: String?) {
        self.status = status
        self.totalSteps = totalSteps
        self.totalTokens = totalTokens
        self.estimatedCost = estimatedCost
        self.summary = summary
    }
}

public struct ObservationData: Sendable, Codable {
    /// Type of observation (screenshot, accessibility, etc.)
    public let observationType: String
    
    /// Path to screenshot file (if applicable)
    public let screenshotPath: String?
    
    /// Screen dimensions
    public let screenWidth: Int?
    public let screenHeight: Int?
    
    /// Additional metadata
    public let metadata: [String: String]?
    
    public init(
        observationType: String,
        screenshotPath: String? = nil,
        screenWidth: Int? = nil,
        screenHeight: Int? = nil,
        metadata: [String: String]? = nil
    ) {
        self.observationType = observationType
        self.screenshotPath = screenshotPath
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.metadata = metadata
    }
}

public struct LLMRequestData: Sendable, Codable {
    /// Number of messages in the request
    public let messageCount: Int
    
    /// Number of tools provided
    public let toolCount: Int
    
    /// Model used
    public let model: String
    
    /// Temperature setting
    public let temperature: Double?
    
    /// Max tokens setting
    public let maxTokens: Int?
    
    public init(
        messageCount: Int,
        toolCount: Int,
        model: String,
        temperature: Double?,
        maxTokens: Int?
    ) {
        self.messageCount = messageCount
        self.toolCount = toolCount
        self.model = model
        self.temperature = temperature
        self.maxTokens = maxTokens
    }
}

public struct LLMResponseData: Sendable, Codable {
    /// Response ID from the API
    public let responseId: String
    
    /// Model that generated the response
    public let model: String
    
    /// Finish reason
    public let finishReason: String?
    
    /// Number of tool calls in the response
    public let toolCallCount: Int
    
    /// Token usage
    public let promptTokens: Int
    public let completionTokens: Int
    public let totalTokens: Int
    
    /// Truncated content preview (first 500 chars)
    public let contentPreview: String?
    
    /// Full response text (only stored when toolCallCount == 0)
    public let responseText: String?
    
    /// Reasoning/thinking content from models that support reasoning tokens (optional for backward compatibility)
    public let reasoning: String?
    
    public init(
        responseId: String,
        model: String,
        finishReason: String?,
        toolCallCount: Int,
        promptTokens: Int,
        completionTokens: Int,
        totalTokens: Int,
        contentPreview: String?,
        responseText: String? = nil,
        reasoning: String? = nil
    ) {
        self.responseId = responseId
        self.model = model
        self.finishReason = finishReason
        self.toolCallCount = toolCallCount
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.contentPreview = contentPreview
        self.responseText = responseText
        self.reasoning = reasoning
    }
}

public struct ToolCallData: Sendable, Codable {
    /// Tool call ID
    public let toolCallId: String
    
    /// Tool/function name
    public let toolName: String
    
    /// Arguments (JSON string)
    public let arguments: String
    
    public init(toolCallId: String, toolName: String, arguments: String) {
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.arguments = arguments
    }
}

public struct ToolResultData: Sendable, Codable {
    /// Tool call ID this is responding to
    public let toolCallId: String
    
    /// Tool/function name
    public let toolName: String
    
    /// Whether the tool execution succeeded
    public let success: Bool
    
    /// Truncated result preview (first 1000 chars)
    public let resultPreview: String?
    
    /// Error message if failed
    public let errorMessage: String?
    
    public init(
        toolCallId: String,
        toolName: String,
        success: Bool,
        resultPreview: String?,
        errorMessage: String?
    ) {
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.success = success
        self.resultPreview = resultPreview
        self.errorMessage = errorMessage
    }
}

public struct UserInterventionData: Sendable, Codable {
    /// Type of intervention (pause, instruction, takeover, resume, cancel)
    public let interventionType: String
    
    /// Optional message from user
    public let message: String?
    
    public init(interventionType: String, message: String?) {
        self.interventionType = interventionType
        self.message = message
    }
}

public struct ErrorData: Sendable, Codable {
    /// Error type/code
    public let errorType: String
    
    /// Error message
    public let message: String
    
    /// Whether the error is recoverable
    public let recoverable: Bool
    
    public init(errorType: String, message: String, recoverable: Bool) {
        self.errorType = errorType
        self.message = message
        self.recoverable = recoverable
    }
}
