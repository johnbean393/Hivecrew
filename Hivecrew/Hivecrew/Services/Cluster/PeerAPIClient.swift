//
//  PeerAPIClient.swift
//  Hivecrew
//
//  HTTP client for calling a peer Hivecrew instance's REST API via its tunnel URL
//

import Foundation
import HivecrewAPI

actor PeerAPIClient {
    let baseURL: String
    let clusterToken: String
    private let session: URLSession
    
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
    
    init(baseURL: String, clusterToken: String) {
        self.baseURL = baseURL
        self.clusterToken = clusterToken
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
    }
    
    // MARK: - Health
    
    func health() async -> Bool {
        guard let url = URL(string: "\(baseURL)/health") else { return false }
        do {
            let (_, response) = try await session.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
    
    // MARK: - System
    
    func systemStatus() async throws -> APISystemStatus {
        return try await get("/api/v1/system/status")
    }
    
    func getClusterStatus() async throws -> APIClusterStatus {
        return try await get("/api/v1/cluster/status")
    }
    
    // MARK: - Providers
    
    func getProviders() async throws -> APIProviderListResponse {
        return try await get("/api/v1/providers")
    }
    
    func getProviderModels(providerId: String) async throws -> APIModelListResponse {
        return try await get("/api/v1/providers/\(providerId)/models")
    }
    
    /// Fetch full provider capability summary (names + model IDs) from the peer.
    func fetchProviderCapabilities() async throws -> [PeerProviderSummary] {
        let providersResponse: APIProviderListResponse = try await get("/api/v1/providers")
        var summaries: [PeerProviderSummary] = []
        
        for provider in providersResponse.providers {
            let modelsResponse: APIModelListResponse = try await get("/api/v1/providers/\(provider.id)/models")
            summaries.append(PeerProviderSummary(
                providerName: provider.displayName,
                modelIds: modelsResponse.models.map(\.id)
            ))
        }
        
        return summaries
    }
    
    // MARK: - Tasks
    
    func createTask(
        description: String,
        providerName: String,
        modelId: String,
        reasoningEnabled: Bool?,
        reasoningEffort: String?,
        attachedFilePaths: [String],
        outputDirectory: String?,
        planFirst: Bool,
        mentionedSkillNames: [String],
        referencedTaskIds: [String],
        continuationSourceTaskId: String?,
        contextPackId: String?,
        contextSuggestionIds: [String],
        contextModeOverrides: [String: String],
        contextInlineBlocks: [String],
        contextAttachmentPaths: [String]
    ) async throws -> APITask {
        let body = CreateTaskBody(
            description: description,
            providerName: providerName,
            modelId: modelId,
            reasoningEnabled: reasoningEnabled,
            reasoningEffort: reasoningEffort,
            attachedFilePaths: attachedFilePaths,
            outputDirectory: outputDirectory,
            planFirst: planFirst,
            mentionedSkillNames: mentionedSkillNames,
            referencedTaskIds: referencedTaskIds,
            continuationSourceTaskId: continuationSourceTaskId,
            contextPackId: contextPackId,
            contextSuggestionIds: contextSuggestionIds,
            contextModeOverrides: contextModeOverrides,
            contextInlineBlocks: contextInlineBlocks,
            contextAttachmentPaths: contextAttachmentPaths
        )
        return try await post("/api/v1/tasks", body: body)
    }
    
    func getTask(id: String) async throws -> APITask {
        return try await get("/api/v1/tasks/\(id)")
    }
    
    func getTasks(
        status: [String]? = nil,
        limit: Int = 100,
        offset: Int = 0,
        sortBy: String = "createdAt",
        order: String = "desc"
    ) async throws -> APITaskListResponse {
        var queryItems = [
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "offset", value: "\(offset)"),
            URLQueryItem(name: "sort", value: sortBy),
            URLQueryItem(name: "order", value: order)
        ]
        if let status {
            for s in status {
                queryItems.append(URLQueryItem(name: "status", value: s))
            }
        }
        return try await get("/api/v1/tasks", queryItems: queryItems)
    }
    
    func performAction(taskId: String, action: String, instructions: String? = nil) async throws -> APITask {
        var body: [String: String] = ["action": action]
        if let instructions { body["instructions"] = instructions }
        return try await patch("/api/v1/tasks/\(taskId)", body: body)
    }
    
    func getScreenshot(taskId: String) async throws -> (data: Data, mimeType: String)? {
        guard let url = URL(string: "\(baseURL)/api/v1/tasks/\(taskId)/screenshot") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(clusterToken)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return nil
        }
        let mimeType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "image/png"
        return (data, mimeType)
    }
    
    func getActivity(taskId: String, since: Int) async throws -> APIActivityResponse {
        return try await get("/api/v1/tasks/\(taskId)/activity", queryItems: [
            URLQueryItem(name: "since", value: "\(since)")
        ])
    }
    
    func answerQuestion(taskId: String, questionId: String, answer: String) async throws {
        let body = ["questionId": questionId, "answer": answer]
        let _: EmptyOKResponse = try await post("/api/v1/tasks/\(taskId)/question/answer", body: body)
    }
    
    func respondToPermission(taskId: String, permissionId: String, approved: Bool) async throws {
        let body = PermissionResponseBody(permissionId: permissionId, approved: approved)
        let _: EmptyOKResponse = try await post("/api/v1/tasks/\(taskId)/permission/respond", body: body)
    }
    
    // MARK: - HTTP Helpers
    
    private func get<R: Decodable>(_ path: String, queryItems: [URLQueryItem] = []) async throws -> R {
        guard var components = URLComponents(string: "\(baseURL)\(path)") else {
            throw PeerAPIError.invalidURL
        }
        if !queryItems.isEmpty { components.queryItems = queryItems }
        guard let url = components.url else { throw PeerAPIError.invalidURL }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(clusterToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await execute(request)
    }
    
    private func post<B: Encodable, R: Decodable>(_ path: String, body: B) async throws -> R {
        guard let url = URL(string: "\(baseURL)\(path)") else { throw PeerAPIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(clusterToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder.encode(body)
        return try await execute(request)
    }
    
    private func patch<B: Encodable, R: Decodable>(_ path: String, body: B) async throws -> R {
        guard let url = URL(string: "\(baseURL)\(path)") else { throw PeerAPIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(clusterToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder.encode(body)
        return try await execute(request)
    }
    
    private func execute<R: Decodable>(_ request: URLRequest) async throws -> R {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PeerAPIError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw PeerAPIError.httpError(statusCode: httpResponse.statusCode)
        }
        return try Self.decoder.decode(R.self, from: data)
    }
}

// MARK: - Request Bodies

private struct CreateTaskBody: Encodable {
    let description: String
    let providerName: String
    let modelId: String
    let reasoningEnabled: Bool?
    let reasoningEffort: String?
    let attachedFilePaths: [String]
    let outputDirectory: String?
    let planFirst: Bool
    let mentionedSkillNames: [String]
    let referencedTaskIds: [String]
    let continuationSourceTaskId: String?
    let contextPackId: String?
    let contextSuggestionIds: [String]
    let contextModeOverrides: [String: String]
    let contextInlineBlocks: [String]
    let contextAttachmentPaths: [String]
}

private struct PermissionResponseBody: Encodable {
    let permissionId: String
    let approved: Bool
}

private struct EmptyOKResponse: Decodable {}

// MARK: - Errors

enum PeerAPIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid peer URL"
        case .invalidResponse: return "Invalid response from peer"
        case .httpError(let code): return "Peer returned HTTP \(code)"
        }
    }
}
