//
//  AuthMiddleware.swift
//  HivecrewAPI
//
//  API key authentication middleware with localhost bypass
//

import Foundation
import Hummingbird
import HTTPTypes
import NIOCore

/// Middleware for API key authentication
public struct AuthMiddleware<Context: RequestContext>: RouterMiddleware, Sendable {
    private let apiKey: String?
    private let pathPrefix: String?
    
    public init(apiKey: String?, pathPrefix: String? = nil) {
        self.apiKey = apiKey
        self.pathPrefix = pathPrefix
    }
    
    public func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        // Skip auth for paths that don't match the prefix
        if let prefix = pathPrefix {
            let path = request.uri.path
            if !path.hasPrefix(prefix) {
                return try await next(request, context)
            }
        }
        
        // API key is always required
        guard let expectedKey = apiKey, !expectedKey.isEmpty else {
            throw APIError.unauthorized("API key not configured. Generate an API key in Settings → API.")
        }
        
        // Check Authorization header
        guard let authHeader = request.headers[.authorization] else {
            throw APIError.unauthorized("Missing Authorization header. Use: Authorization: Bearer <api_key>")
        }
        
        // Extract Bearer token
        let headerValue = String(authHeader)
        guard headerValue.hasPrefix("Bearer ") else {
            throw APIError.unauthorized("Invalid Authorization header format. Expected: Bearer <api_key>")
        }
        
        let providedKey = String(headerValue.dropFirst(7))
        
        // Validate API key
        guard providedKey == expectedKey else {
            throw APIError.unauthorized("Invalid API key")
        }
        
        return try await next(request, context)
    }
}
