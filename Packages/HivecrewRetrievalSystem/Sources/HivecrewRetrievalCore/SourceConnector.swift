import Foundation
import HivecrewRetrievalProtocol

public enum SourceBackfillMode: String, Codable, Sendable {
    case full
    case incremental
}

public protocol SourceConnector: Sendable {
    var sourceType: RetrievalSourceType { get }
    func start(handler: @escaping @Sendable ([IngestionEvent]) async -> Void)
    func stop()
    func runBackfill(
        resumeToken: String?,
        mode: SourceBackfillMode,
        policy: IndexingPolicy,
        limit: Int,
        handler: @escaping @Sendable ([IngestionEvent], BackfillCheckpoint) async -> Void
    ) async throws -> BackfillCheckpoint?
}
