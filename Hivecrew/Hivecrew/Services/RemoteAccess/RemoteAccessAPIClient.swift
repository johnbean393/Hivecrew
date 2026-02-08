//
//  RemoteAccessAPIClient.swift
//  Hivecrew
//
//  HTTP client for the Hivecrew remote access coordination Worker API
//

import Foundation

/// HTTP client for the Hivecrew remote access Cloudflare Worker API
actor RemoteAccessAPIClient {
    
    /// Default base URL for the coordination Worker
    private static let defaultBaseURL = "https://remoteaccessauthapi.hivecrew.org"
    
    /// Base URL for the coordination Worker, configurable via UserDefaults
    static var baseURL: String {
        let stored = UserDefaults.standard.string(forKey: "remoteAccessWorkerURL")
        return (stored?.isEmpty == false) ? stored! : defaultBaseURL
    }
    
    private let session: URLSession
    
    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }
    
    // MARK: - Auth Endpoints
    
    /// Request an OTP code to be sent to the given email
    func register(email: String) async throws {
        let body: [String: String] = ["email": email]
        let _: MessageResponse = try await post("/auth/register", body: body)
    }
    
    /// Verify an OTP code and receive a session JWT
    func verify(email: String, code: String) async throws -> String {
        let body: [String: String] = ["email": email, "code": code]
        let response: VerifyResponse = try await post("/auth/verify", body: body)
        return response.token
    }
    
    // MARK: - Tunnel Endpoints
    
    /// Create a new tunnel. Returns tunnel info including the tunnel token.
    func createTunnel(sessionToken: String) async throws -> TunnelCreateResponse {
        return try await post("/tunnels", body: EmptyBody(), token: sessionToken)
    }
    
    /// Get the current user's tunnel info
    func getTunnel(sessionToken: String) async throws -> TunnelGetResponse {
        return try await get("/tunnels", token: sessionToken)
    }
    
    /// Delete a tunnel
    func deleteTunnel(tunnelId: String, sessionToken: String) async throws {
        let _: MessageResponse = try await delete("/tunnels/\(tunnelId)", token: sessionToken)
    }
    
    /// Send a heartbeat for a tunnel
    func heartbeat(tunnelId: String, sessionToken: String) async throws {
        let _: MessageResponse = try await post(
            "/tunnels/\(tunnelId)/heartbeat",
            body: EmptyBody(),
            token: sessionToken
        )
    }
    
    // MARK: - HTTP Helpers
    
    private func get<R: Decodable>(_ path: String, token: String? = nil) async throws -> R {
        let url = URL(string: Self.baseURL + path)!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        return try await execute(request)
    }
    
    private func post<B: Encodable, R: Decodable>(
        _ path: String,
        body: B,
        token: String? = nil
    ) async throws -> R {
        let url = URL(string: Self.baseURL + path)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        if !(body is EmptyBody) {
            request.httpBody = try JSONEncoder().encode(body)
        }
        
        return try await execute(request)
    }
    
    private func delete<R: Decodable>(_ path: String, token: String? = nil) async throws -> R {
        let url = URL(string: Self.baseURL + path)!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        return try await execute(request)
    }
    
    private func execute<R: Decodable>(_ request: URLRequest) async throws -> R {
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteAccessError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            // Try to parse error message from response
            if let errorResponse = try? JSONDecoder().decode(ErrorBody.self, from: data) {
                throw RemoteAccessError.serverError(
                    statusCode: httpResponse.statusCode,
                    message: errorResponse.error
                )
            }
            throw RemoteAccessError.httpError(statusCode: httpResponse.statusCode)
        }
        
        return try JSONDecoder().decode(R.self, from: data)
    }
}

// MARK: - Request / Response Types

private struct EmptyBody: Encodable {}

private struct MessageResponse: Decodable {
    let message: String
}

private struct VerifyResponse: Decodable {
    let token: String
}

struct TunnelCreateResponse: Decodable {
    let tunnelId: String
    let subdomain: String
    let tunnelToken: String
    let url: String
    let createdAt: Double
}

struct TunnelInfo: Decodable {
    let tunnelId: String
    let subdomain: String
    let url: String
    let createdAt: Double
    let lastHeartbeat: Double
}

struct TunnelGetResponse: Decodable {
    let tunnel: TunnelInfo?
}

private struct ErrorBody: Decodable {
    let error: String
}

// MARK: - Errors

enum RemoteAccessError: LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int)
    case serverError(statusCode: Int, message: String)
    case notAuthenticated
    case tunnelNotConfigured
    case cloudflaredNotFound
    case cloudflaredStartFailed(String)
    case cloudflaredCrashed(Int32)
    
    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let statusCode):
            return "HTTP error \(statusCode)"
        case .serverError(_, let message):
            return message
        case .notAuthenticated:
            return "Not authenticated. Please verify your email."
        case .tunnelNotConfigured:
            return "No tunnel configured. Please set up remote access."
        case .cloudflaredNotFound:
            return "cloudflared binary not found in app bundle"
        case .cloudflaredStartFailed(let reason):
            return "Failed to start cloudflared: \(reason)"
        case .cloudflaredCrashed(let code):
            return "cloudflared exited unexpectedly (code \(code))"
        }
    }
}
