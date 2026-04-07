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

/// Middleware for API key, session cookie, and cluster token authentication
public struct AuthMiddleware<Context: RequestContext>: RouterMiddleware, Sendable {
    private let apiKey: String?
    private let pathPrefix: String?
    private let deviceSessionManager: DeviceSessionManager?
    private let clusterToken: String?
    
    /// Paths that bypass authentication entirely (pairing endpoints)
    private let unauthenticatedPrefixes: [String]
    
    /// Cluster endpoints that accept cluster token instead of API key
    private let clusterTokenPrefixes: [String] = [
        "/api/v1/cluster/announce",
        "/api/v1/cluster/task-update",
        "/api/v1/cluster/depart"
    ]
    
    public init(
        apiKey: String?,
        pathPrefix: String? = nil,
        deviceSessionManager: DeviceSessionManager? = nil,
        unauthenticatedPrefixes: [String] = [],
        clusterToken: String? = nil
    ) {
        self.apiKey = apiKey
        self.pathPrefix = pathPrefix
        self.deviceSessionManager = deviceSessionManager
        self.unauthenticatedPrefixes = unauthenticatedPrefixes
        self.clusterToken = clusterToken
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
        
        // Cluster token auth for worker→coordinator endpoints
        let isClusterEndpoint = clusterTokenPrefixes.contains { path.hasPrefix($0) }
        if isClusterEndpoint, let expectedClusterToken = clusterToken, !expectedClusterToken.isEmpty {
            if let authHeader = request.headers[.authorization] {
                let headerValue = String(authHeader)
                if headerValue.hasPrefix("Bearer ") {
                    let providedToken = String(headerValue.dropFirst(7))
                    if providedToken == expectedClusterToken {
                        return try await next(request, context)
                    }
                }
            }
            throw APIError.unauthorized("Invalid cluster token.")
        }
        
        // Method 1: Check Authorization header (Bearer token / API key)
        if let authHeader = request.headers[.authorization] {
            let headerValue = String(authHeader)
            if headerValue.hasPrefix("Bearer ") {
                let providedKey = String(headerValue.dropFirst(7))
                
                if let expectedKey = apiKey, !expectedKey.isEmpty, providedKey == expectedKey {
                    return try await next(request, context)
                }
                
                // Also accept cluster token for all API endpoints (coordinator calling worker)
                if let expectedClusterToken = clusterToken, !expectedClusterToken.isEmpty,
                   providedKey == expectedClusterToken {
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
                    await deviceSessionManager.updateLastSeen(deviceId: device.id)
                    return try await next(request, context)
                }
            }
        }
        
        // Neither method succeeded
        if apiKey == nil || apiKey?.isEmpty == true {
            if deviceSessionManager == nil {
                throw APIError.unauthorized("API key not configured. Generate an API key in Settings → API.")
            }
        }
        
        throw APIError.unauthorized("Authentication required. Use a Bearer token or authorize this device via pairing.")
    }
}
