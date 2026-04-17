//
//  RemoteAccessAPIClient.swift
//  Hivecrew
//
//  HTTP client for the Hivecrew remote access coordination Worker API
//

import Foundation

/// HTTP client for the Hivecrew remote access Cloudflare Worker API
public actor RemoteAccessAPIClient {

    /// Default base URL for the coordination Worker
    private static let defaultBaseURL = "https://remoteaccessauthapi.hivecrew.org"

    /// Base URL for the coordination Worker, configurable via UserDefaults
    public static var baseURL: String {
        let stored = UserDefaults.standard.string(forKey: "remoteAccessWorkerURL")
        return (stored?.isEmpty == false) ? stored! : defaultBaseURL
    }

    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    // MARK: - Auth Endpoints

    /// Request an OTP code to be sent to the given email
    public func register(email: String) async throws {
        let body: [String: String] = ["email": email]
        let _: MessageResponse = try await post("/auth/register", body: body)
    }

    /// Verify an OTP code and receive a session JWT
    public func verify(email: String, code: String) async throws -> String {
        let body: [String: String] = ["email": email, "code": code]
        let response: VerifyResponse = try await post("/auth/verify", body: body)
        return response.token
    }

    /// Revoke the current session and unregister this device's push record when an owner ID is provided.
    public func logout(sessionToken: String, ownerId: String?) async throws {
        let body = LogoutRequest(ownerId: ownerId)
        let _: MessageResponse = try await post("/auth/logout", body: body, token: sessionToken)
    }

    /// Delete the authenticated account and revoke all active sessions.
    public func deleteAccount(sessionToken: String) async throws {
        let _: MessageResponse = try await delete("/auth/account", token: sessionToken)
    }

    // MARK: - Tunnel Endpoints

    /// Create a new tunnel (supports multiple per account). Returns tunnel info including the tunnel token.
    public func createTunnel(sessionToken: String, name: String? = nil) async throws -> TunnelCreateResponse {
        let body = CreateTunnelRequest(name: name)
        return try await post("/tunnels", body: body, token: sessionToken)
    }

    /// Get all tunnels for the authenticated account
    public func getTunnels(sessionToken: String) async throws -> TunnelsGetResponse {
        return try await get("/tunnels", token: sessionToken)
    }

    /// Delete a tunnel
    public func deleteTunnel(tunnelId: String, sessionToken: String) async throws {
        let _: MessageResponse = try await delete("/tunnels/\(tunnelId)", token: sessionToken)
    }

    /// Send a heartbeat for a tunnel
    public func heartbeat(tunnelId: String, sessionToken: String) async throws {
        let _: MessageResponse = try await post(
            "/tunnels/\(tunnelId)/heartbeat",
            body: EmptyBody(),
            token: sessionToken
        )
    }

    // MARK: - Cluster Endpoints

    /// Get cluster mesh info for the authenticated account.
    public func getClusterInfo(sessionToken: String) async throws -> ClusterInfoResponse {
        return try await get("/cluster/mesh-info", token: sessionToken)
    }

    /// Ensure a cluster token exists for the authenticated account and join the mesh view.
    public func ensureCluster(sessionToken: String) async throws -> ClusterInfoResponse {
        return try await post("/cluster/ensure", body: EmptyBody(), token: sessionToken)
    }

    // MARK: - Device Push Registration

    /// Register a device's push tokens with the Worker API so the server can
    /// send VoIP and standard APNs notifications to this device.
    public func registerDevice(
        sessionToken: String,
        ownerId: String,
        voipToken: String? = nil,
        apnsToken: String? = nil,
        bundleId: String? = nil,
        apnsEnvironment: String? = nil
    ) async throws {
        let body = DeviceRegistrationRequest(
            ownerId: ownerId,
            voipToken: voipToken,
            apnsToken: apnsToken,
            platform: "ios",
            bundleId: bundleId ?? Bundle.main.bundleIdentifier ?? "",
            apnsEnvironment: apnsEnvironment
        )
        let _: MessageResponse = try await post("/devices/register", body: body, token: sessionToken)
    }

    // MARK: - VoIP Push Delivery

    /// Ask the coordination Worker to deliver a VoIP push notification to all
    /// devices registered under `targetOwnerId`. The Worker looks up the
    /// stored VoIP token and sends via APNs.
    public func sendVoIPPush(
        sessionToken: String,
        targetOwnerId: String,
        payload: VoIPPushPayload
    ) async throws {
        let body = VoIPPushRequest(
            targetOwnerId: targetOwnerId,
            trigger: payload.trigger,
            taskId: payload.taskId,
            workerName: payload.workerName,
            summary: payload.summary,
            peerId: payload.peerId
        )
        let _: MessageResponse = try await post("/push/send-voip", body: body, token: sessionToken)
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

private struct LogoutRequest: Encodable {
    let ownerId: String?
}

private struct CreateTunnelRequest: Encodable {
    let name: String?
}

struct DeviceRegistrationRequest: Encodable {
    let ownerId: String
    let voipToken: String?
    let apnsToken: String?
    let platform: String
    let bundleId: String
    let apnsEnvironment: String?
}

public struct VoIPPushPayload: Sendable {
    public let trigger: String
    public let taskId: String
    public let workerName: String
    public let summary: String
    public let peerId: String

    public init(trigger: String, taskId: String, workerName: String, summary: String, peerId: String) {
        self.trigger = trigger
        self.taskId = taskId
        self.workerName = workerName
        self.summary = summary
        self.peerId = peerId
    }
}

private struct VoIPPushRequest: Encodable {
    let targetOwnerId: String
    let trigger: String
    let taskId: String
    let workerName: String
    let summary: String
    let peerId: String
}

public struct TunnelCreateResponse: Decodable {
    public let tunnelId: String
    public let subdomain: String
    public let tunnelToken: String
    public let url: String
    public let createdAt: Double
}

public struct TunnelInfo: Decodable {
    public let tunnelId: String
    public let subdomain: String
    public let url: String
    public let createdAt: Double
    public let lastHeartbeat: Double
    public let name: String?
    public let role: String?
}

public struct TunnelsGetResponse: Decodable {
    public let tunnels: [TunnelInfo]
}

// MARK: - Cluster Request / Response Types

public struct ClusterInfoResponse: Decodable, Sendable {
    public let hasCluster: Bool
    public let clusterToken: String?
    public let peers: [ClusterPeerInfo]
    public let meshEnabled: Bool?
}

public struct ClusterPeerInfo: Decodable, Sendable {
    public let tunnelId: String
    public let subdomain: String
    public let name: String?
    public let url: String
    public let lastHeartbeat: Double
}

private struct ErrorBody: Decodable {
    let error: String
}

// MARK: - Errors

public enum RemoteAccessError: LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int)
    case serverError(statusCode: Int, message: String)
    case notAuthenticated
    case tunnelNotConfigured
    case cloudflaredNotFound
    case cloudflaredStartFailed(String)
    case cloudflaredCrashed(Int32)

    public var errorDescription: String? {
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
