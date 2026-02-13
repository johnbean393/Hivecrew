import Foundation
import HivecrewRetrievalProtocol

public struct RetrievalClientConfiguration: Sendable {
    public let baseURL: URL
    public let authToken: String
    public let requestTimeoutSeconds: TimeInterval
    public let maxRetries: Int

    public init(
        baseURL: URL,
        authToken: String,
        requestTimeoutSeconds: TimeInterval = 1.5,
        maxRetries: Int = 2
    ) {
        self.baseURL = baseURL
        self.authToken = authToken
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.maxRetries = maxRetries
    }
}

public actor RetrievalDaemonClient {
    private let configuration: RetrievalClientConfiguration
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(configuration: RetrievalClientConfiguration) {
        self.configuration = configuration
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = configuration.requestTimeoutSeconds
        sessionConfiguration.timeoutIntervalForResource = configuration.requestTimeoutSeconds * 2
        self.session = URLSession(configuration: sessionConfiguration)
    }

    public func healthCheck() async throws -> RetrievalHealth {
        try await sendRequest(
            path: RetrievalAPIPath.health,
            method: "GET",
            requestBody: Optional<String>.none
        )
    }

    public func suggest(_ request: RetrievalSuggestRequest) async throws -> RetrievalSuggestResponse {
        try await sendRequest(path: RetrievalAPIPath.suggest, method: "POST", requestBody: request)
    }

    public func streamSuggestions(
        query: String,
        sourceFilters: [RetrievalSourceType]?,
        limit: Int
    ) -> AsyncThrowingStream<RetrievalSuggestResponse, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    // First pass for typing-time responsiveness.
                    let fast = try await suggest(
                        RetrievalSuggestRequest(
                            query: query,
                            sourceFilters: sourceFilters,
                            limit: limit,
                            typingMode: true,
                            includeColdPartitionFallback: false
                        )
                    )
                    continuation.yield(fast)

                    // Second pass with deeper rerank/cold fallback.
                    let refined = try await suggest(
                        RetrievalSuggestRequest(
                            query: query,
                            sourceFilters: sourceFilters,
                            limit: limit,
                            typingMode: false,
                            includeColdPartitionFallback: true
                        )
                    )
                    continuation.yield(refined)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func createContextPack(_ request: RetrievalCreateContextPackRequest) async throws -> RetrievalContextPack {
        try await sendRequest(path: RetrievalAPIPath.createContextPack, method: "POST", requestBody: request)
    }

    public func getDocumentPreview(itemId: String) async throws -> RetrievalSuggestion? {
        struct PreviewPayload: Codable {
            let itemId: String
        }
        return try await sendRequest(path: RetrievalAPIPath.preview, method: "POST", requestBody: PreviewPayload(itemId: itemId))
    }

    public func getStateSnapshot() async throws -> RetrievalStateSnapshot {
        try await sendRequest(path: RetrievalAPIPath.state, method: "GET", requestBody: Optional<String>.none)
    }

    public func getIndexingProgress() async throws -> [RetrievalProgressState] {
        try await sendRequest(path: RetrievalAPIPath.progress, method: "GET", requestBody: Optional<String>.none)
    }

    public func getIndexStats() async throws -> RetrievalIndexStats {
        try await sendRequest(path: RetrievalAPIPath.indexStats, method: "GET", requestBody: Optional<String>.none)
    }

    public func getQueueActivity() async throws -> RetrievalQueueActivity {
        try await sendRequest(path: RetrievalAPIPath.activity, method: "GET", requestBody: Optional<String>.none)
    }

    public func listBackfillJobs() async throws -> [RetrievalBackfillJob] {
        try await sendRequest(path: RetrievalAPIPath.backfillJobs, method: "GET", requestBody: Optional<String>.none)
    }

    public func pauseBackfill(jobId: String) async throws {
        struct Payload: Codable {
            let jobId: String
        }
        let _: EmptyResponse = try await sendRequest(path: RetrievalAPIPath.pauseBackfill, method: "POST", requestBody: Payload(jobId: jobId))
    }

    public func resumeBackfill(jobId: String) async throws {
        struct Payload: Codable {
            let jobId: String
        }
        let _: EmptyResponse = try await sendRequest(path: RetrievalAPIPath.resumeBackfill, method: "POST", requestBody: Payload(jobId: jobId))
    }

    public func configureSourceScopes(_ request: RetrievalConfigureScopesRequest) async throws {
        let _: EmptyResponse = try await self.sendRequest(path: RetrievalAPIPath.configureScopes, method: "POST", requestBody: request)
    }

    public func triggerBackfill() async throws {
        let _: EmptyResponse = try await sendRequest(path: RetrievalAPIPath.triggerBackfill, method: "POST", requestBody: EmptyRequest())
    }

    private func sendRequest<RequestBody: Encodable, ResponseBody: Decodable>(
        path: String,
        method: String,
        requestBody: RequestBody
    ) async throws -> ResponseBody {
        var lastError: Error?
        for attempt in 0...configuration.maxRetries {
            do {
                var request = URLRequest(url: configuration.baseURL.appending(path: path))
                request.httpMethod = method
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(configuration.authToken, forHTTPHeaderField: RetrievalAPIHeader.authToken)
                if method != "GET" {
                    request.httpBody = try encoder.encode(requestBody)
                }

                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }
                guard (200...299).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }

                if ResponseBody.self == EmptyResponse.self {
                    return EmptyResponse() as! ResponseBody
                }
                return try decoder.decode(ResponseBody.self, from: data)
            } catch {
                lastError = error
                if attempt < configuration.maxRetries {
                    let delayMs = Int(pow(2, Double(attempt)) * 80)
                    try? await Task.sleep(for: .milliseconds(delayMs))
                }
            }
        }
        throw lastError ?? URLError(.unknown)
    }
}

private struct EmptyRequest: Codable {}
private struct EmptyResponse: Codable {}

