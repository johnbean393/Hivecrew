//
//  AuthMiddleware.swift
//  HivecrewAPI
//
//  API key and device session authentication middleware
//

import Foundation
import Hummingbird
import HTTPTypes
import NIOCore

/// Middleware for API key and session cookie authentication
public struct AuthMiddleware<Context: RequestContext>: RouterMiddleware, Sendable {
    private let apiKey: String?
    private let pathPrefix: String?
    private let deviceSessionManager: DeviceSessionManager?
    
    /// Paths that bypass authentication entirely (pairing endpoints)
    private let unauthenticatedPrefixes: [String]
    
    public init(
        apiKey: String?,
        pathPrefix: String? = nil,
        deviceSessionManager: DeviceSessionManager? = nil,
        unauthenticatedPrefixes: [String] = []
    ) {
        self.apiKey = apiKey
        self.pathPrefix = pathPrefix
        self.deviceSessionManager = deviceSessionManager
        self.unauthenticatedPrefixes = unauthenticatedPrefixes
    }
    
    public func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        let path = request.uri.path
        
        // Skip auth for paths that don't match the prefix
        if let prefix = pathPrefix {
            if !path.hasPrefix(prefix) {
                return try await next(request, context)
            }
        }
        
        // Skip auth for explicitly unauthenticated paths (pairing, auth check)
        for prefix in unauthenticatedPrefixes {
            if path.hasPrefix(prefix) {
                return try await next(request, context)
            }
        }
        
        // Method 1: Check Authorization header (Bearer token / API key)
        if let authHeader = request.headers[.authorization] {
            let headerValue = String(authHeader)
            if headerValue.hasPrefix("Bearer ") {
                let providedKey = String(headerValue.dropFirst(7))
                
                if let expectedKey = apiKey, !expectedKey.isEmpty, providedKey == expectedKey {
                    return try await next(request, context)
                }
            }
        }
        
        // Method 2: Check session cookie
        if let deviceSessionManager = deviceSessionManager,
           let cookieHeader = request.headers[.cookie] {
            let cookies = String(cookieHeader)
            if let token = DeviceAuthRoutes.extractCookieValue(named: "hivecrew_session", from: cookies) {
                if let device = await deviceSessionManager.validateSession(token: token) {
                    // Valid session — update last seen timestamp
                    await deviceSessionManager.updateLastSeen(deviceId: device.id)
                    return try await next(request, context)
                }
            }
        }
        
        // Neither method succeeded — check if API key is even configured
        if apiKey == nil || apiKey?.isEmpty == true {
            // If no API key is configured and no session manager, require setup
            if deviceSessionManager == nil {
                throw APIError.unauthorized("API key not configured. Generate an API key in Settings → API.")
            }
        }
        
        throw APIError.unauthorized("Authentication required. Use a Bearer token or authorize this device via pairing.")
    }
}
