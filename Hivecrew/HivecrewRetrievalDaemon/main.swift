//
//  main.swift
//  HivecrewRetrievalDaemon
//
//  Standalone retrieval daemon executable entrypoint.
//

import Foundation
import Hummingbird
import HivecrewRetrievalCore
import HivecrewRetrievalProtocol
import HTTPTypes
import NIOCore
import NIOPosix
import Logging

struct RetrievalDaemonRequestContext: RequestContext {
    var coreContext: CoreRequestContextStorage

    init(source: Source) {
        self.coreContext = .init(source: source)
    }
}

@main
enum HivecrewRetrievalDaemonMain {
    static func main() async throws {
        let logger = Logger(label: "com.hivecrew.retrievald")
        let paths = try RetrievalPaths.resolve()
        let config = try RetrievalDaemonConfiguration.load(from: paths.daemonConfigPath)
        let service = try RetrievalService(configuration: config, paths: paths)
        await service.start()

        let router = Router(context: RetrievalDaemonRequestContext.self)
        router.get("health") { _, _ in
            let health = await service.health()
            let data = try JSONEncoder().encode(health)
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(data: data)))
        }

        let app = Application(
            router: router,
            configuration: .init(
                address: .hostname(config.host, port: config.port),
                serverName: "HivecrewRetrievalDaemon"
            ),
            logger: logger
        )
        try await app.run()
    }
}

