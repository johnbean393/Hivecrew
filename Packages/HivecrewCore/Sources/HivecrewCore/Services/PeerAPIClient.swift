//
//  PeerAPIClient.swift
//  Hivecrew
//
//  HTTP client for calling a peer Hivecrew instance's REST API via its tunnel URL
//

import Foundation
import HivecrewAPIModels

public enum PeerHealthResult: Sendable, Equatable {
    case reachable
    case dnsUnavailable
    case unreachable

    public var isReachable: Bool {
        self == .reachable
    }
}

public actor PeerAPIClient {
    public struct StagedLocalFileUpload: Sendable {
        public let localPath: String
        public let uploadFilename: String

        public init(localPath: String, uploadFilename: String) {
            self.localPath = localPath
            self.uploadFilename = uploadFilename
        }
    }

    public let baseURL: String
    public let clusterToken: String
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

    public init(baseURL: String, clusterToken: String) {
        self.baseURL = baseURL
        self.clusterToken = clusterToken

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    // MARK: - Health

    public func health() async -> Bool {
        await healthResult().isReachable
    }

    public func healthResult() async -> PeerHealthResult {
        guard let url = URL(string: "\(baseURL)/health") else { return .unreachable }
        let request = URLRequest(url: url)
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200 ? .reachable : .unreachable
        } catch let error as URLError where error.code == .cannotFindHost {
            do {
                let (_, response) = try await PeerHTTPFallbackClient.data(for: request)
                return response.statusCode == 200 ? .reachable : .unreachable
            } catch PeerHTTPFallbackClient.FallbackError.noAddress {
                return .dnsUnavailable
            } catch {
                return .unreachable
            }
        } catch {
            return .unreachable
        }
    }

    // MARK: - System

    public func systemStatus() async throws -> APISystemStatus {
        return try await get("/api/v1/system/status")
    }

    public func getClusterStatus() async throws -> APIClusterStatus {
        return try await get("/api/v1/cluster/status")
    }

    // MARK: - Providers

    public func getProviders() async throws -> APIProviderListResponse {
        return try await get("/api/v1/providers")
    }

    public func getSkills() async throws -> [APISkill] {
        let response: APISkillListResponse = try await get("/api/v1/skills")
        return response.skills
    }

    public func getProviderModels(providerId: String) async throws -> APIModelListResponse {
        return try await get("/api/v1/providers/\(providerId)/models")
    }

    /// Fetch full provider capability summary (names + model IDs) from the peer.
    public func fetchProviderCapabilities() async throws -> [PeerProviderSummary] {
        let clusterStatus = try await getClusterStatus()
        if !clusterStatus.localProviders.isEmpty {
            return Self.normalizedProviderCapabilities(clusterStatus.localProviders)
        }

        let providersResponse: APIProviderListResponse = try await get("/api/v1/providers")
        var summaries: [PeerProviderSummary] = []

        for provider in providersResponse.providers {
            let modelsResponse: APIModelListResponse = try await get("/api/v1/providers/\(provider.id)/models")
            summaries.append(PeerProviderSummary(
                providerName: provider.displayName,
                modelIds: modelsResponse.models.map(\.id)
            ))
        }

        return Self.normalizedProviderCapabilities(summaries)
    }

    static func normalizedProviderCapabilities(_ summaries: [PeerProviderSummary]) -> [PeerProviderSummary] {
        var modelIdsByProvider: [String: [String]] = [:]
        var seenModelIdsByProvider: [String: Set<String>] = [:]
        var orderedProviderNames: [String] = []
        var seenProviderNames = Set<String>()

        for summary in summaries {
            let providerName = summary.providerName
            if seenProviderNames.insert(providerName).inserted {
                orderedProviderNames.append(providerName)
            }

            var modelIds = modelIdsByProvider[providerName] ?? []
            var seenModelIds = seenModelIdsByProvider[providerName] ?? []
            for modelId in summary.modelIds where seenModelIds.insert(modelId).inserted {
                modelIds.append(modelId)
            }
            modelIdsByProvider[providerName] = modelIds
            seenModelIdsByProvider[providerName] = seenModelIds
        }

        return orderedProviderNames.map { providerName in
            PeerProviderSummary(providerName: providerName, modelIds: modelIdsByProvider[providerName] ?? [])
        }
    }

    // MARK: - Tasks

    public func executeNow(_ request: ClusterExecuteNowRequest) async throws -> ClusterExecuteNowResponse {
        return try await post("/api/v1/cluster/execute-now", body: request)
    }

    public func createTask(
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

    public func getTask(id: String) async throws -> APITask {
        return try await get("/api/v1/tasks/\(id)")
    }

    public func getTasks(
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

    public func getTaskFiles(taskId: String, canonicalTaskId: String) async throws -> APITaskFilesResponse {
        let response: APITaskFilesResponse = try await get("/api/v1/tasks/\(taskId)/files")
        return APITaskFilesResponse(taskId: canonicalTaskId, inputFiles: response.inputFiles, outputFiles: response.outputFiles)
    }

    public func downloadTaskFile(taskId: String, filename: String, isInput: Bool) async throws -> (data: Data, mimeType: String) {
        let typeQuery = isInput ? "?type=input" : ""
        guard let url = URL(string: "\(baseURL)/api/v1/tasks/\(taskId)/files/\(filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename)\(typeQuery)") else {
            throw PeerAPIError.invalidURL
        }
        return try await fetchBinary(url: url)
    }

    public func getTraceBundle(taskId: String, canonicalTaskId: String) async throws -> APITaskTraceBundleResponse {
        let response: APITaskTraceBundleResponse = try await get("/api/v1/tasks/\(taskId)/trace-bundle")
        return APITaskTraceBundleResponse(taskId: canonicalTaskId, files: response.files)
    }

    public func downloadTraceFile(taskId: String, relativePath: String) async throws -> (data: Data, mimeType: String) {
        guard var components = URLComponents(string: "\(baseURL)/api/v1/tasks/\(taskId)/trace-file") else {
            throw PeerAPIError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "path", value: relativePath)]
        guard let url = components.url else { throw PeerAPIError.invalidURL }
        return try await fetchBinary(url: url)
    }

    public func performAction(taskId: String, action: String, instructions: String? = nil) async throws -> APITask {
        var body: [String: String] = ["action": action]
        if let instructions { body["instructions"] = instructions }
        return try await patch("/api/v1/tasks/\(taskId)", body: body)
    }

    public func getScreenshot(taskId: String) async throws -> (data: Data, mimeType: String)? {
        guard let url = URL(string: "\(baseURL)/api/v1/tasks/\(taskId)/screenshot") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(clusterToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return nil
        }
        let mimeType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "image/png"
        return (data, mimeType)
    }

    public func getActivity(taskId: String, since: Int) async throws -> APIActivityResponse {
        return try await get("/api/v1/tasks/\(taskId)/activity", queryItems: [
            URLQueryItem(name: "since", value: "\(since)")
        ])
    }

    public func getPendingQuestion(taskId: String) async throws -> APIAgentQuestion? {
        guard let url = URL(string: "\(baseURL)/api/v1/tasks/\(taskId)/question") else {
            throw PeerAPIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(clusterToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PeerAPIError.invalidResponse }
        if http.statusCode == 204 { return nil }
        guard (200...299).contains(http.statusCode) else {
            throw PeerAPIError.httpError(statusCode: http.statusCode)
        }
        return try Self.decoder.decode(APIAgentQuestion.self, from: data)
    }

    public func answerQuestion(taskId: String, questionId: String, answer: String) async throws {
        let body = ["questionId": questionId, "answer": answer]
        let _: EmptyOKResponse = try await post("/api/v1/tasks/\(taskId)/question/answer", body: body)
    }

    public func respondToPermission(taskId: String, permissionId: String, approved: Bool) async throws {
        let body = PermissionResponseBody(permissionId: permissionId, approved: approved)
        let _: EmptyOKResponse = try await post("/api/v1/tasks/\(taskId)/permission/respond", body: body)
    }

    public func stageInputFiles(stagingId: String, filePaths: [String]) async throws -> [String] {
        let uploads = filePaths.map { path in
            StagedLocalFileUpload(
                localPath: path,
                uploadFilename: URL(fileURLWithPath: path).lastPathComponent
            )
        }
        return try await stageInputFiles(stagingId: stagingId, uploads: uploads)
    }

    public func stageInputFiles(stagingId: String, uploads: [StagedLocalFileUpload]) async throws -> [String] {
        guard !uploads.isEmpty else { return [] }

        let boundary = "HivecrewBoundary-\(UUID().uuidString)"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("hivecrew-cluster-stage-\(UUID().uuidString).multipart")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tempURL)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: tempURL)
        }

        try handle.write(contentsOf: Data("--\(boundary)\r\n".utf8))
        try handle.write(contentsOf: Data("Content-Disposition: form-data; name=\"stagingId\"\r\n\r\n".utf8))
        try handle.write(contentsOf: Data("\(stagingId)\r\n".utf8))

        for upload in uploads {
            let fileURL = URL(fileURLWithPath: upload.localPath)
            let filename = upload.uploadFilename
            let mimeType = APIFile.mimeType(for: fileURL.lastPathComponent)
            try handle.write(contentsOf: Data("--\(boundary)\r\n".utf8))
            try handle.write(contentsOf: Data("Content-Disposition: form-data; name=\"files\"; filename=\"\(filename)\"\r\n".utf8))
            try handle.write(contentsOf: Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
            let fileData = try Data(contentsOf: fileURL)
            try handle.write(contentsOf: fileData)
            try handle.write(contentsOf: Data("\r\n".utf8))
        }

        try handle.write(contentsOf: Data("--\(boundary)--\r\n".utf8))

        guard let url = URL(string: "\(baseURL)/api/v1/cluster/stage-inputs") else {
            throw PeerAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(clusterToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(for: request, fromFile: tempURL)
        } catch let error as URLError where error.code == .cannotFindHost {
            var fallbackRequest = request
            fallbackRequest.httpBody = try Data(contentsOf: tempURL)
            (data, response) = try await PeerHTTPFallbackClient.data(for: fallbackRequest)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PeerAPIError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw PeerAPIError.httpError(statusCode: httpResponse.statusCode)
        }
        let decoded = try Self.decoder.decode(ClusterStageInputFilesResponse.self, from: data)
        return decoded.stagedFilePaths
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
        let (data, response) = try await data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PeerAPIError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw PeerAPIError.httpError(statusCode: httpResponse.statusCode, detail: Self.extractErrorDetail(from: data))
        }
        return try Self.decoder.decode(R.self, from: data)
    }

    private func fetchBinary(url: URL) async throws -> (data: Data, mimeType: String) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(clusterToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PeerAPIError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw PeerAPIError.httpError(statusCode: httpResponse.statusCode, detail: Self.extractErrorDetail(from: data))
        }
        return (data, httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream")
    }

    private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError where error.code == .cannotFindHost {
            return try await PeerHTTPFallbackClient.data(for: request)
        }
    }

    private static func extractErrorDetail(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errorObj = json["error"] as? [String: Any],
              let message = errorObj["message"] as? String else {
            return nil
        }
        return message
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

private struct ClusterStageInputFilesResponse: Decodable {
    let stagedFilePaths: [String]
}

private struct EmptyOKResponse: Decodable {}

// MARK: - Errors

public enum PeerAPIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int, detail: String? = nil)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid peer URL"
        case .invalidResponse: return "Invalid response from peer"
        case .httpError(let code, let detail):
            if let detail, !detail.isEmpty {
                return "Peer returned HTTP \(code): \(detail)"
            }
            return "Peer returned HTTP \(code)"
        }
    }
}
