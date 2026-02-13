import Foundation
import HivecrewRetrievalProtocol

public protocol SourceConnector: Sendable {
    var sourceType: RetrievalSourceType { get }
    func start(handler: @escaping @Sendable ([IngestionEvent]) async -> Void)
    func stop()
    func runBackfill(
        resumeToken: String?,
        policy: IndexingPolicy,
        limit: Int,
        handler: @escaping @Sendable ([IngestionEvent], BackfillCheckpoint) async -> Void
    ) async throws -> BackfillCheckpoint?
}
