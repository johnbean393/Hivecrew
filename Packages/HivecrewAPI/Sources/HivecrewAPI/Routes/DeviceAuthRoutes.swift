//
//  DeviceAuthRoutes.swift
//  HivecrewAPI
//
//  Routes for device pairing authentication: /api/v1/auth/*
//

import Foundation
import Hummingbird
import NIOCore
import HTTPTypes

/// Register device authentication routes
public struct DeviceAuthRoutes: Sendable {
    let deviceSessionManager: DeviceSessionManager
    let sessionMaxAgeDays: Int
    
    public init(deviceSessionManager: DeviceSessionManager, sessionMaxAgeDays: Int = 180) {
        self.deviceSessionManager = deviceSessionManager
        self.sessionMaxAgeDays = sessionMaxAgeDays
    }
    
    public func register(with router: any RouterMethods<APIRequestContext>) {
        let auth = router.group("auth")
        let pair = auth.group("pair")
        
        // Pairing endpoints (no auth required — these ARE the auth mechanism)
        
        // POST /auth/pair/request - Request a pairing code
        pair.post("request", use: requestPairing)
        
        // GET /auth/pair/status - Poll pairing status
        pair.get("status", use: getPairingStatus)
        
        // Auth check (no auth required — used to test if authenticated)
        // GET /auth/check - Check if current request is authenticated
        auth.get("check", use: checkAuth)
        
        // Authenticated endpoints
        
        // POST /auth/logout - Log out (clear session cookie)
        auth.post("logout", use: logout)
        
        // GET /auth/devices - List authorized devices
        auth.get("devices", use: listDevices)
        
        // DELETE /auth/devices/:id - Revoke an authorized device
        auth.delete("devices/{id}", use: revokeDevice)
    }
    
    // MARK: - Pairing Handlers
    
    @Sendable
    func requestPairing(request: Request, context: APIRequestContext) async throws -> Response {
        let userAgent = request.headers[.userAgent] ?? "Unknown"
        
        let (pairingId, code) = await deviceSessionManager.createPairing(userAgent: userAgent)
        
        let response = PairingRequestResponse(
            pairingId: pairingId,
            code: code,
            expiresIn: 300
        )
        
        return try createJSONResponse(response, status: .created)
    }
    
    @Sendable
    func getPairingStatus(request: Request, context: APIRequestContext) async throws -> Response {
        let queryItems = parseQueryItems(from: request.uri.description)
        
        guard let pairingId = queryItems["id"], !pairingId.isEmpty else {
            throw APIError.badRequest("Missing required query parameter: id")
        }
        
        guard let pairing = await deviceSessionManager.getPairingStatus(pairingId: pairingId) else {
            throw APIError.notFound("Pairing request not found or expired")
        }
        
        let statusResponse = PairingStatusResponse(
            status: pairing.status,
            deviceName: pairing.status == .approved ? pairing.deviceInfo.displayName : nil
        )
        
        // If approved, set the session cookie
        if pairing.status == .approved, let sessionToken = pairing.sessionToken {
            var response = try createJSONResponse(statusResponse)
            let maxAge = sessionMaxAgeDays * 24 * 3600
            let cookieValue = "hivecrew_session=\(sessionToken); Path=/; HttpOnly; SameSite=Lax; Max-Age=\(maxAge)"
            response.headers[.setCookie] = cookieValue
            return response
        }
        
        return try createJSONResponse(statusResponse)
    }
    
    // MARK: - Auth Check
    
    @Sendable
    func checkAuth(request: Request, context: APIRequestContext) async throws -> Response {
        // Check for Bearer token
        if let authHeader = request.headers[.authorization] {
            let headerValue = String(authHeader)
            if headerValue.hasPrefix("Bearer ") {
                // Bearer token present — the auth middleware will have validated it
                // if we get here with a Bearer token, it means auth middleware let us through
                return try createJSONResponse(AuthCheckResponse(authenticated: true, method: "bearer"))
            }
        }
        
        // Check for session cookie
        if let cookieHeader = request.headers[.cookie] {
            let cookies = String(cookieHeader)
            if let token = Self.extractCookieValue(named: "hivecrew_session", from: cookies) {
                if await deviceSessionManager.validateSession(token: token) != nil {
                    return try createJSONResponse(AuthCheckResponse(authenticated: true, method: "cookie"))
                }
            }
        }
        
        // Not authenticated — return 200 with authenticated=false
        // (we don't throw 401 because this endpoint is specifically for checking)
        return try createJSONResponse(AuthCheckResponse(authenticated: false))
    }
    
    // MARK: - Session Management
    
    @Sendable
    func logout(request: Request, context: APIRequestContext) async throws -> Response {
        // Revoke the device if authenticated via cookie
        if let cookieHeader = request.headers[.cookie] {
            let cookies = String(cookieHeader)
            if let token = Self.extractCookieValue(named: "hivecrew_session", from: cookies) {
                _ = await deviceSessionManager.revokeDeviceByToken(token: token)
            }
        }
        
        // Clear the session cookie
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        headers[.setCookie] = "hivecrew_session=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0"
        
        let body = try JSONEncoder().encode(["status": "logged_out"])
        
        return Response(
            status: .ok,
            headers: headers,
            body: .init(byteBuffer: ByteBuffer(data: body))
        )
    }
    
    // MARK: - Device Management
    
    @Sendable
    func listDevices(request: Request, context: APIRequestContext) async throws -> Response {
        let devices = await deviceSessionManager.listDevices()
        let response = DeviceListResponse(
            devices: devices.map { DeviceResponse(from: $0) }
        )
        return try createJSONResponse(response)
    }
    
    @Sendable
    func revokeDevice(request: Request, context: APIRequestContext) async throws -> Response {
        guard let deviceId = context.parameters.get("id") else {
            throw APIError.badRequest("Missing device ID")
        }
        
        let removed = await deviceSessionManager.revokeDevice(id: deviceId)
        guard removed else {
            throw APIError.notFound("Device not found")
        }
        
        return Response(status: .noContent)
    }
    
    // MARK: - Cookie Parsing
    
    /// Extract a cookie value by name from a Cookie header string
    static func extractCookieValue(named name: String, from cookieHeader: String) -> String? {
        let pairs = cookieHeader.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        for pair in pairs {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2 && parts[0] == name {
                return String(parts[1])
            }
        }
        return nil
    }
}
