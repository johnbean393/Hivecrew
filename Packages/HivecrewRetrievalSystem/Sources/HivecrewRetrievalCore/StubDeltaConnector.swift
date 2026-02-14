import Foundation
import HivecrewRetrievalProtocol

public final class StubDeltaConnector: SourceConnector, @unchecked Sendable {
    public let sourceType: RetrievalSourceType
    private var pollingTask: Task<Void, Never>?

    public init(sourceType: RetrievalSourceType) {
        self.sourceType = sourceType
    }

    public func start(handler: @escaping @Sendable ([IngestionEvent]) async -> Void) {
        stop()
        pollingTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                await handler([])
                try? await Task.sleep(for: .seconds(45))
            }
        }
    }

    public func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    public func runBackfill(
        resumeToken: String?,
        mode: SourceBackfillMode,
        policy: IndexingPolicy,
        limit: Int,
        handler: @escaping @Sendable ([IngestionEvent], BackfillCheckpoint) async -> Void
    ) async throws -> BackfillCheckpoint? {
        _ = mode
        _ = policy
        _ = limit
        let checkpoint = BackfillCheckpoint(
            key: "\(sourceType.rawValue):default",
            sourceType: sourceType,
            scopeLabel: "default",
            cursor: nil,
            lastIndexedPath: nil,
            lastIndexedTimestamp: nil,
            resumeToken: resumeToken,
            itemsProcessed: 0,
            itemsSkipped: 0,
            estimatedTotal: 0,
            status: "idle"
        )
        await handler([], checkpoint)
        return checkpoint
    }
}
