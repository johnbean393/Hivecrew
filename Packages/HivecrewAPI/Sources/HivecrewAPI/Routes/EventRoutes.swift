//
//  EventRoutes.swift
//  HivecrewAPI
//
//  Routes for /api/v1/tasks/:id/events (Server-Sent Events)
//

import Foundation
import Hummingbird
import Logging
import NIOCore
import HTTPTypes

/// Register SSE routes for real-time task progress streaming
public struct EventRoutes: Sendable {
    let serviceProvider: APIServiceProvider
    private let logger = Logger(label: "com.pattonium.api.events")

    public init(serviceProvider: APIServiceProvider) {
        self.serviceProvider = serviceProvider
    }

    public func register(with router: any RouterMethods<APIRequestContext>) {
        let tasks = router.group("tasks")

        // GET /tasks/:id/events - Stream task events via SSE
        tasks.get(":id/events", use: streamTaskEvents)
    }

    // MARK: - Route Handlers

    @Sendable
    func streamTaskEvents(request: Request, context: APIRequestContext) async throws -> Response {
        guard let taskId = context.parameters.get("id") else {
            throw APIError.badRequest("Missing task ID")
        }

        logger.info("SSE stream requested for task \(taskId)")

        // Subscribe to the event stream from the main app's service provider.
        // This may throw if the task does not exist.
        let eventStream = try await serviceProvider.subscribeToTaskEvents(id: taskId)

        logger.info("SSE stream created for task \(taskId), starting response")

        // Prepend a heartbeat comment followed by the real event stream.
        // The heartbeat forces headers + first chunk to flush immediately,
        // so the client's fetch() promise resolves without delay.
        let heartbeat = AsyncStream<ByteBuffer> { continuation in
            let comment = ByteBuffer(string: ": connected\n\n")
            continuation.yield(comment)
            continuation.finish()
        }

        // Map each APITaskEvent to an SSE-formatted ByteBuffer
        let dataStream = eventStream.map { (event: APITaskEvent) -> ByteBuffer in
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let jsonData = (try? encoder.encode(event)) ?? Data()
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
            // SSE format: event: <type>\ndata: <json>\n\n
            let sseMessage = "event: \(event.type.rawValue)\ndata: \(jsonString)\n\n"
            return ByteBuffer(string: sseMessage)
        }

        // Chain: heartbeat comment, then real events
        let combined = AsyncConcatenatedSequence(heartbeat, dataStream)

        // Build SSE response headers
        var headers = HTTPFields()
        headers[.contentType] = "text/event-stream"
        headers[.cacheControl] = "no-cache"
        headers[.connection] = "keep-alive"

        return Response(
            status: .ok,
            headers: headers,
            body: .init(asyncSequence: combined)
        )
    }
}

// MARK: - Async Sequence Concatenation

/// Concatenates two async sequences of the same element type into one.
struct AsyncConcatenatedSequence<S1: AsyncSequence, S2: AsyncSequence>: AsyncSequence, Sendable
where S1.Element == S2.Element, S1: Sendable, S2: Sendable, S1.Element: Sendable {
    typealias Element = S1.Element

    let first: S1
    let second: S2

    init(_ first: S1, _ second: S2) {
        self.first = first
        self.second = second
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(first: first.makeAsyncIterator(), second: second.makeAsyncIterator())
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        var first: S1.AsyncIterator
        var second: S2.AsyncIterator
        var firstDone = false

        mutating func next() async throws -> Element? {
            if !firstDone {
                if let element = try await first.next() {
                    return element
                }
                firstDone = true
            }
            return try await second.next()
        }
    }
}
