import Foundation
import Hummingbird
import HivecrewRetrievalCore
import HivecrewRetrievalProtocol
import HTTPTypes
import NIOCore
import NIOPosix
import Logging

struct RetrievalRequestContext: RequestContext {
    var coreContext: CoreRequestContextStorage

    init(source: Source) {
        self.coreContext = .init(source: source)
    }
}

struct RetrievalTokenMiddleware: RouterMiddleware {
    typealias Context = RetrievalRequestContext
    let token: String

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        let path = request.uri.path
        if path == RetrievalAPIPath.health {
            return try await next(request, context)
        }
        let supplied = request.headers[HTTPField.Name(RetrievalAPIHeader.authToken)!]
        guard supplied == token else {
            return try jsonResponse(
                ["error": "unauthorized"],
                status: .unauthorized
            )
        }
        return try await next(request, context)
    }
}

struct EmptyResponse: Codable {}

@main
enum RetrievalDaemonMain {
    static func main() async throws {
        let logger = Logger(label: "com.hivecrew.retrievald")
        let paths = try RetrievalPaths.resolve()
        let config = try ensureConfiguration(paths: paths)
        let service = try RetrievalService(configuration: config, paths: paths)
        let sleepWakeMonitor = SleepWakeMonitor(
            onSleep: {
                await service.pauseForSystemSleep()
            },
            onWake: {
                await service.resumeAfterSystemWake()
            }
        )
        await service.start()
        await MainActor.run {
            sleepWakeMonitor.start()
        }

        let router = Router(context: RetrievalRequestContext.self)
        router.middlewares.add(RetrievalTokenMiddleware(token: config.authToken))

        router.get("health") { _, _ in
            let health = await service.health()
            return try jsonResponse(health)
        }

        let retrieval = router.group("api/v1/retrieval")
        let backfill = retrieval.group("backfill")

        retrieval.post("suggest") { request, _ in
            let payload = try await decodeBody(RetrievalSuggestRequest.self, request: request)
            let result = try await service.suggest(request: payload)
            return try jsonResponse(result)
        }

        retrieval.post("context-pack") { request, _ in
            let payload = try await decodeBody(RetrievalCreateContextPackRequest.self, request: request)
            let pack = try await service.createContextPack(request: payload)
            return try jsonResponse(pack)
        }

        retrieval.post("preview") { request, _ in
            struct PreviewRequest: Codable { let itemId: String }
            let payload = try await decodeBody(PreviewRequest.self, request: request)
            let preview = try await service.preview(itemId: payload.itemId)
            return try jsonResponse(preview)
        }

        retrieval.get("state") { _, _ in
            let state = try await service.stateSnapshot()
            return try jsonResponse(state)
        }

        retrieval.get("progress") { _, _ in
            let progress = try await service.indexingProgress()
            return try jsonResponse(progress)
        }

        retrieval.get("index-stats") { _, _ in
            let stats = try await service.indexStats()
            return try jsonResponse(stats)
        }

        retrieval.get("activity") { _, _ in
            let activity = await service.queueActivity()
            return try jsonResponse(activity)
        }

        backfill.get("jobs") { _, _ in
            let jobs = try await service.listBackfillJobs()
            return try jsonResponse(jobs)
        }

        backfill.post("pause") { request, _ in
            struct BackfillControlRequest: Codable { let jobId: String }
            let payload = try await decodeBody(BackfillControlRequest.self, request: request)
            await service.pauseBackfill(jobId: payload.jobId)
            return try jsonResponse(EmptyResponse())
        }

        backfill.post("resume") { request, _ in
            struct BackfillControlRequest: Codable { let jobId: String }
            let payload = try await decodeBody(BackfillControlRequest.self, request: request)
            await service.resumeBackfill(jobId: payload.jobId)
            return try jsonResponse(EmptyResponse())
        }

        retrieval.post("scopes") { request, _ in
            let payload = try await decodeBody(RetrievalConfigureScopesRequest.self, request: request)
            try await service.configureScopes(payload)
            return try jsonResponse(EmptyResponse())
        }

        backfill.post("trigger") { _, _ in
            _ = try await service.triggerBackfill()
            return try jsonResponse(EmptyResponse())
        }

        let app = Application(
            router: router,
            configuration: .init(
                address: .hostname(config.host, port: config.port),
                serverName: "HivecrewRetrievalDaemon"
            ),
            logger: logger
        )
        do {
            try await app.run()
        } catch {
            await MainActor.run {
                sleepWakeMonitor.stop()
            }
            await service.stop()
            throw error
        }
        await MainActor.run {
            sleepWakeMonitor.stop()
        }
        await service.stop()
    }

    private static func ensureConfiguration(paths: RetrievalPaths) throws -> RetrievalDaemonConfiguration {
        let fm = FileManager.default
        if fm.fileExists(atPath: paths.daemonConfigPath.path) {
            return try RetrievalDaemonConfiguration.load(from: paths.daemonConfigPath)
        }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let defaultConfig = RetrievalDaemonConfiguration(
            authToken: token,
            startupAllowlistRoots: [
                fm.homeDirectoryForCurrentUser.appendingPathComponent("Documents").path,
                fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").path,
            ]
        )
        let data = try JSONEncoder().encode(defaultConfig)
        try data.write(to: paths.daemonConfigPath, options: .atomic)
        return defaultConfig
    }
}

private func decodeBody<T: Decodable>(_ type: T.Type, request: Request) async throws -> T {
    let buffer = try await request.body.collect(upTo: 5 * 1024 * 1024)
    let bytes = buffer.readableBytesView
    return try JSONDecoder().decode(T.self, from: Data(bytes))
}

private func jsonResponse<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) throws -> Response {
    let data = try JSONEncoder().encode(value)
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    return Response(
        status: status,
        headers: headers,
        body: .init(byteBuffer: ByteBuffer(data: data))
    )
}

