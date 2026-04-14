//
//  APIError.swift
//  HivecrewAPIModels
//
//  Standard error response model (Foundation-only, no Hummingbird dependency)
//

import Foundation

/// Standard API error codes
public enum APIErrorCode: String, Codable, Sendable {
    case badRequest = "bad_request"
    case unauthorized = "unauthorized"
    case notFound = "not_found"
    case conflict = "conflict"
    case payloadTooLarge = "payload_too_large"
    case internalError = "internal_error"
    case badGateway = "bad_gateway"
}

/// Error detail for API responses
public struct APIErrorDetail: Codable, Sendable {
    public let code: String
    public let message: String
    public let details: String?
    
    public init(code: APIErrorCode, message: String, details: String? = nil) {
        self.code = code.rawValue
        self.message = message
        self.details = details
    }
}

/// Wrapper for error responses
public struct APIErrorResponse: Codable, Sendable {
    public let error: APIErrorDetail
    
    public init(code: APIErrorCode, message: String, details: String? = nil) {
        self.error = APIErrorDetail(code: code, message: message, details: details)
    }
}
