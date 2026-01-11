//
//  LLMError.swift
//  HivecrewLLM
//
//  Error types for LLM operations
//

import Foundation

/// Errors that can occur during LLM operations
public enum LLMError: Error, Sendable, LocalizedError {
    /// The API returned an error response
    case apiError(statusCode: Int, message: String)
    
    /// Network connection failed
    case networkError(underlying: Error)
    
    /// Failed to encode the request
    case encodingError(underlying: Error)
    
    /// Failed to decode the response
    case decodingError(underlying: Error)
    
    /// The API key is missing or invalid
    case authenticationError(message: String)
    
    /// Rate limit exceeded
    case rateLimitError(retryAfter: TimeInterval?)
    
    /// Request timeout
    case timeout
    
    /// Invalid configuration
    case invalidConfiguration(message: String)
    
    /// Tool arguments couldn't be parsed
    case invalidToolArguments(String)
    
    /// No response choices returned
    case noChoices
    
    /// The request was cancelled
    case cancelled
    
    /// An unknown error occurred
    case unknown(message: String)
    
    public var errorDescription: String? {
        switch self {
        case .apiError(let statusCode, let message):
            return "API Error (\(statusCode)): \(message)"
        case .networkError(let underlying):
            return "Network Error: \(underlying.localizedDescription)"
        case .encodingError(let underlying):
            return "Encoding Error: \(underlying.localizedDescription)"
        case .decodingError(let underlying):
            return "Decoding Error: \(underlying.localizedDescription)"
        case .authenticationError(let message):
            return "Authentication Error: \(message)"
        case .rateLimitError(let retryAfter):
            if let retryAfter = retryAfter {
                return "Rate Limit Exceeded. Retry after \(Int(retryAfter)) seconds."
            }
            return "Rate Limit Exceeded"
        case .timeout:
            return "Request Timeout"
        case .invalidConfiguration(let message):
            return "Invalid Configuration: \(message)"
        case .invalidToolArguments(let message):
            return "Invalid Tool Arguments: \(message)"
        case .noChoices:
            return "No response choices returned"
        case .cancelled:
            return "Request Cancelled"
        case .unknown(let message):
            return "Unknown Error: \(message)"
        }
    }
    
    /// Whether this error is retryable
    public var isRetryable: Bool {
        switch self {
        case .networkError, .timeout, .rateLimitError:
            return true
        case .apiError(let statusCode, _):
            // 5xx errors are retryable
            return statusCode >= 500 && statusCode < 600
        default:
            return false
        }
    }
}
