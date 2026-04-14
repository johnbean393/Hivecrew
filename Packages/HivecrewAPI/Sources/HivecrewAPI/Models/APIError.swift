//
//  APIError.swift
//  HivecrewAPI
//
//  Server-side API error with HTTP status (requires Hummingbird)
//

import Foundation
import Hummingbird
import HivecrewAPIModels

/// API error that can be thrown and converted to HTTP response
public struct APIError: Error, Sendable {
    public let status: HTTPResponse.Status
    public let response: APIErrorResponse
    
    public init(status: HTTPResponse.Status, code: APIErrorCode, message: String, details: String? = nil) {
        self.status = status
        self.response = APIErrorResponse(code: code, message: message, details: details)
    }
    
    // MARK: - Convenience initializers
    
    public static func badRequest(_ message: String, details: String? = nil) -> APIError {
        APIError(status: .badRequest, code: .badRequest, message: message, details: details)
    }
    
    public static func unauthorized(_ message: String = "Invalid or missing API key") -> APIError {
        APIError(status: .unauthorized, code: .unauthorized, message: message)
    }
    
    public static func notFound(_ message: String) -> APIError {
        APIError(status: .notFound, code: .notFound, message: message)
    }
    
    public static func conflict(_ message: String) -> APIError {
        APIError(status: .conflict, code: .conflict, message: message)
    }
    
    public static func payloadTooLarge(_ message: String) -> APIError {
        APIError(status: .contentTooLarge, code: .payloadTooLarge, message: message)
    }
    
    public static func internalError(_ message: String = "An internal error occurred") -> APIError {
        APIError(status: .internalServerError, code: .internalError, message: message)
    }
    
    public static func badGateway(_ message: String) -> APIError {
        APIError(status: .badGateway, code: .badGateway, message: message)
    }
}
