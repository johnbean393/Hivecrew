import Foundation

enum RetrievalIndexStateDeriver {
    static func nextPollingDelaySeconds(
        consecutiveErrorCount: Int,
        snapshot: RetrievalStatePayload?
    ) -> Double {
        if consecutiveErrorCount > 0 {
            return min(20, pow(2, Double(consecutiveErrorCount)) * 1.2)
        }
        if isIndexingNow(snapshot) {
            return 3
        }
        return 4
    }

    static func overallStatus(
        enabled: Bool,
        snapshot: RetrievalStatePayload?
    ) -> RetrievalIndexStatusKind {
        guard enabled else { return .disabled }
        guard let snapshot else { return .unavailable }
        if let error = snapshot.health.lastError, !error.isEmpty {
            return .needsAttention
        }
        if !snapshot.health.running {
            return .unavailable
        }
        if snapshot.health.inFlightCount > 0 || snapshot.queueActivity.queueDepth > 0 {
            return .indexing
        }
        if snapshot.sourceRuntime.contains(where: { $0.inFlightCount > 0 || $0.queueDepth > 0 }) {
            return .indexing
        }
        if snapshot.indexStats.totalDocumentCount == 0 {
            return .notStarted
        }
        return .ready
    }

    static func sourceStatus(
        for sourceKey: String,
        enabled: Bool,
        snapshot: RetrievalStatePayload?
    ) -> RetrievalIndexStatusKind {
        guard enabled else { return .disabled }
        guard let snapshot else { return .unavailable }
        if let error = snapshot.health.lastError, !error.isEmpty {
            return .needsAttention
        }
        guard snapshot.health.running else { return .unavailable }
        let runtime = runtimeRow(for: sourceKey, snapshot: snapshot)
        let progressRows = progressRows(for: sourceKey, snapshot: snapshot)
        let checkpointTerminal = progressRows.allSatisfy { isTerminalCheckpointStatus($0.status) }
        let indexed = statsRow(for: sourceKey, snapshot: snapshot)?.documentCount ?? 0
        if (runtime?.inFlightCount ?? 0) > 0 || (runtime?.queueDepth ?? 0) > 0 {
            return .indexing
        }
        if !checkpointTerminal && !progressRows.isEmpty {
            return .indexing
        }
        if (indexed > 0 || (runtime?.cumulativeProcessedCount ?? 0) > 0) && checkpointTerminal {
            return .ready
        }
        return .notStarted
    }

    static func runtimeRow(
        for sourceKey: String,
        snapshot: RetrievalStatePayload?
    ) -> RetrievalSourceRuntimePayload? {
        snapshot?.sourceRuntime.first(where: { $0.sourceType.lowercased() == sourceKey.lowercased() })
    }

    static func statsRow(
        for sourceKey: String,
        snapshot: RetrievalStatePayload?
    ) -> RetrievalSourceStatsPayload? {
        snapshot?.indexStats.sources.first(where: { $0.sourceType.lowercased() == sourceKey.lowercased() })
    }

    static func progressRows(
        for sourceKey: String,
        snapshot: RetrievalStatePayload?
    ) -> [RetrievalProgressPayload] {
        (snapshot?.progress ?? []).filter { $0.sourceType.lowercased() == sourceKey.lowercased() }
    }

    static func emptySourceDetail(
        entry: RetrievalSidebarEntry,
        status: RetrievalIndexStatusKind
    ) -> RetrievalSourceDetailModel {
        RetrievalSourceDetailModel(
            entry: entry,
            status: status,
            progress: 0,
            indexedItems: 0,
            queueDepth: 0,
            inFlightCount: 0,
            cumulativeProcessedCount: 0,
            scopeCount: 0,
            lastUpdatedAt: nil,
            currentOperation: RetrievalOperationPayload.idle.rawValue.capitalized,
            currentItemPath: nil,
            scanCandidatesSeen: 0,
            scanCandidatesSkippedExcluded: 0,
            scanEventsEmitted: 0,
            extractionSuccessCount: 0,
            extractionPartialCount: 0,
            extractionFailedCount: 0,
            extractionUnsupportedCount: 0,
            extractionOCRCount: 0
        )
    }

    private static func isIndexingNow(_ snapshot: RetrievalStatePayload?) -> Bool {
        guard let snapshot else { return false }
        if snapshot.health.inFlightCount > 0 {
            return true
        }
        if snapshot.queueActivity.queueDepth > 0 {
            return true
        }
        return snapshot.sourceRuntime.contains {
            $0.inFlightCount > 0 || $0.queueDepth > 0 || $0.currentOperation != RetrievalOperationPayload.idle.rawValue
        }
    }

    private static func isTerminalCheckpointStatus(_ status: String) -> Bool {
        let normalized = status.lowercased()
        return normalized == "idle" || normalized == "completed" || normalized == "complete" || normalized == "paused"
    }
}
