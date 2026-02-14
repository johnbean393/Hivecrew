import Foundation
import HivecrewRetrievalProtocol

public actor ConnectorHub {
    private var connectors: [RetrievalSourceType: SourceConnector] = [:]
    private var pausedJobs: Set<String> = []

    public init() {}

    public func register(_ connector: SourceConnector) {
        connectors[connector.sourceType] = connector
    }

    public func startAll(handler: @escaping @Sendable ([IngestionEvent]) async -> Void) {
        for connector in connectors.values {
            connector.start(handler: handler)
        }
    }

    public func stopAll() {
        for connector in connectors.values {
            connector.stop()
        }
    }

    public func runBackfill(
        source: RetrievalSourceType,
        resumeToken: String?,
        mode: SourceBackfillMode,
        policy: IndexingPolicy,
        limit: Int,
        handler: @escaping @Sendable ([IngestionEvent], BackfillCheckpoint) async -> Void
    ) async throws -> BackfillCheckpoint? {
        guard let connector = connectors[source] else {
            return nil
        }
        if pausedJobs.contains("\(source.rawValue):default") {
            return nil
        }
        return try await connector.runBackfill(
            resumeToken: resumeToken,
            mode: mode,
            policy: policy,
            limit: limit,
            handler: handler
        )
    }

    public func pause(jobId: String) {
        pausedJobs.insert(jobId)
    }

    public func resume(jobId: String) {
        pausedJobs.remove(jobId)
    }
}
