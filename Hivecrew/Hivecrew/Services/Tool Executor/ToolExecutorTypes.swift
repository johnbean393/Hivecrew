//
//  ToolExecutorTypes.swift
//  Hivecrew
//
//  Types and models for tool execution
//

import Foundation

/// Result of a tool execution
struct ToolExecutionResult: Sendable {
    let toolCallId: String
    let toolName: String
    let success: Bool
    let result: String
    let errorMessage: String?
    let durationMs: Int
    
    /// For image results: base64-encoded image data to inject into model context
    let imageBase64: String?
    /// For image results: MIME type (e.g., image/jpeg, image/png)
    let imageMimeType: String?
    
    /// Whether this result includes an image that should be injected into the conversation
    var hasImage: Bool { imageBase64 != nil }
    
    static func success(toolCallId: String, toolName: String, result: String, durationMs: Int) -> ToolExecutionResult {
        ToolExecutionResult(
            toolCallId: toolCallId,
            toolName: toolName,
            success: true,
            result: result,
            errorMessage: nil,
            durationMs: durationMs,
            imageBase64: nil,
            imageMimeType: nil
        )
    }
    
    static func successWithImage(
        toolCallId: String,
        toolName: String,
        result: String,
        durationMs: Int,
        imageBase64: String,
        imageMimeType: String
    ) -> ToolExecutionResult {
        ToolExecutionResult(
            toolCallId: toolCallId,
            toolName: toolName,
            success: true,
            result: result,
            errorMessage: nil,
            durationMs: durationMs,
            imageBase64: imageBase64,
            imageMimeType: imageMimeType
        )
    }
    
    static func failure(toolCallId: String, toolName: String, error: String, durationMs: Int) -> ToolExecutionResult {
        ToolExecutionResult(
            toolCallId: toolCallId,
            toolName: toolName,
            success: false,
            result: "",
            errorMessage: error,
            durationMs: durationMs,
            imageBase64: nil,
            imageMimeType: nil
        )
    }
}

/// Internal result type for tool execution (before converting to ToolExecutionResult)
enum InternalToolResult {
    case text(String)
    case image(description: String, base64: String, mimeType: String)
}

/// Errors from tool execution
enum ToolExecutorError: Error, LocalizedError {
    case unknownTool(String)
    case missingParameter(String)
    case executionFailed(String)
    case mcpError(String)
    
    var errorDescription: String? {
        switch self {
        case .unknownTool(let name):
            return "Unknown tool: \(name)"
        case .missingParameter(let param):
            return "Missing required parameter: \(param)"
        case .executionFailed(let reason):
            return "Tool execution failed: \(reason)"
        case .mcpError(let reason):
            return "MCP tool error: \(reason)"
        }
    }
}

// MARK: - Number Parsing Helpers

/// Parse a numeric value that could be Int or Double from JSON
func parseDouble(_ value: Any?, default defaultValue: Double = 0) -> Double {
    if let d = value as? Double { return d }
    if let i = value as? Int { return Double(i) }
    if let n = value as? NSNumber { return n.doubleValue }
    return defaultValue
}

/// Parse an optional numeric value that could be Int or Double from JSON
func parseDoubleOptional(_ value: Any?) -> Double? {
    if value == nil { return nil }
    if let d = value as? Double { return d }
    if let i = value as? Int { return Double(i) }
    if let n = value as? NSNumber { return n.doubleValue }
    return nil
}
