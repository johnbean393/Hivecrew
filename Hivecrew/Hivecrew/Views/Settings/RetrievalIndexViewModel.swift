import Foundation
import SwiftUI
import Combine

enum RetrievalSidebarEntry: String, CaseIterable, Identifiable {
    case overall
    case file

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overall:
            return "Overall"
        case .file:
            return "Files"
        }
    }

    var systemImage: String {
        switch self {
        case .overall:
            return "rectangle.stack"
        case .file:
            return "doc.text"
        }
    }

    var sourceKey: String? {
        switch self {
        case .overall:
            return nil
        case .file:
            return rawValue
        }
    }
}

enum RetrievalIndexStatusKind {
    case disabled
    case unavailable
    case notStarted
    case indexing
    case ready
    case needsAttention

    var title: String {
        switch self {
        case .disabled:
            return "Off"
        case .unavailable:
            return "Unavailable"
        case .notStarted:
            return "Not Started"
        case .indexing:
            return "Indexing"
        case .ready:
            return "Ready"
        case .needsAttention:
            return "Needs Attention"
        }
    }

    var tint: Color {
        switch self {
        case .disabled, .unavailable, .notStarted:
            return .secondary
        case .indexing:
            return .blue
        case .ready:
            return .green
        case .needsAttention:
            return .red
        }
    }
}

struct RetrievalSidebarRowModel: Identifiable {
    let entry: RetrievalSidebarEntry
    let status: RetrievalIndexStatusKind
    let subtitle: String

    var id: String { entry.id }
}

struct RetrievalSourceDetailModel: Identifiable {
    let entry: RetrievalSidebarEntry
    let status: RetrievalIndexStatusKind
    let progress: Double
    let indexedItems: Int
    let queueDepth: Int
    let inFlightCount: Int
    let cumulativeProcessedCount: Int
    let scopeCount: Int
    let lastUpdatedAt: Date?
    let currentOperation: String
    let currentItemPath: String?
    let scanCandidatesSeen: Int
    let scanCandidatesSkippedExcluded: Int
    let scanEventsEmitted: Int
    let extractionSuccessCount: Int
    let extractionPartialCount: Int
    let extractionFailedCount: Int
    let extractionUnsupportedCount: Int
    let extractionOCRCount: Int

    var id: String { entry.id }
}

struct RetrievalOverallDetailModel {
    let status: RetrievalIndexStatusKind
    let totalIndexedItems: Int
    let indexedItemsThisRun: Int
    let totalQueuedItems: Int
    let totalInFlightItems: Int
    let activeSourceCount: Int
    let currentOperation: String
    let currentOperationSource: String?
    let currentItemPath: String?
    let lastUpdatedAt: Date?
    let extractionSuccessCount: Int
    let extractionPartialCount: Int
    let extractionFailedCount: Int
    let extractionUnsupportedCount: Int
    let extractionOCRCount: Int
}

@MainActor
final class RetrievalIndexViewModel: ObservableObject {
    @Published var selectedEntry: RetrievalSidebarEntry = .overall
    @Published private var snapshot: RetrievalStatePayload?
    @Published private(set) var isRefreshing = false
    @Published private(set) var fetchError: String?
    @Published private(set) var lastRefreshAt: Date?
    @Published private(set) var allowlistRoots: [RetrievalAllowlistRoot] = RetrievalDaemonManager.shared.allowlistRootsForDisplay()

    private var pollingTask: Task<Void, Never>?
    private var pollingEnabled = false
    private var consecutiveErrorCount = 0

    func setPollingEnabled(_ enabled: Bool) {
        pollingEnabled = enabled
        if enabled {
            startPollingIfNeeded()
        } else {
            stopPolling()
            snapshot = nil
            fetchError = nil
            lastRefreshAt = Date()
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func refreshNow() async {
        await refreshState()
    }

    @discardableResult
    func addAllowlistRoot(path: String) async -> Bool {
        let added = RetrievalDaemonManager.shared.addAllowlistRoot(path)
        reloadAllowlistRoots()
        guard added else { return false }
        await RetrievalDaemonManager.shared.applyAllowlistRootsToRunningDaemon(triggerBackfill: false)
        await refreshState()
        return true
    }

    @discardableResult
    func removeAllowlistRoot(path: String) async -> Bool {
        let removed = RetrievalDaemonManager.shared.removeAllowlistRoot(path)
        reloadAllowlistRoots()
        guard removed else { return false }
        await RetrievalDaemonManager.shared.applyAllowlistRootsToRunningDaemon(triggerBackfill: false)
        await refreshState()
        return true
    }

    func reloadAllowlistRoots() {
        allowlistRoots = RetrievalDaemonManager.shared.allowlistRootsForDisplay()
    }

    func sidebarRows(enabled: Bool) -> [RetrievalSidebarRowModel] {
        RetrievalSidebarEntry.allCases.map { entry in
            if entry == .overall {
                let overall = overallModel(enabled: enabled)
                let subtitle = "\(overall.totalIndexedItems.formatted()) indexed"
                return RetrievalSidebarRowModel(entry: entry, status: overall.status, subtitle: subtitle)
            }
            let detail = sourceDetail(for: entry, enabled: enabled)
            let subtitle = "\(detail.indexedItems.formatted()) indexed"
            return RetrievalSidebarRowModel(entry: entry, status: detail.status, subtitle: subtitle)
        }
    }

    func sourceDetail(for entry: RetrievalSidebarEntry, enabled: Bool) -> RetrievalSourceDetailModel {
        guard let sourceKey = entry.sourceKey else {
            return emptySourceDetail(entry: entry, status: enabled ? .unavailable : .disabled)
        }
        let status = sourceStatus(for: sourceKey, enabled: enabled)
        let runtime = runtimeRow(for: sourceKey)
        let stats = statsRow(for: sourceKey)
        let indexedItems = stats?.documentCount ?? 0
        let queueDepth = runtime?.queueDepth ?? 0
        let denominator = indexedItems + queueDepth
        let progress = denominator > 0
            ? max(0, min(1, Double(indexedItems) / Double(denominator)))
            : 0

        return RetrievalSourceDetailModel(
            entry: entry,
            status: status,
            progress: progress,
            indexedItems: indexedItems,
            queueDepth: queueDepth,
            inFlightCount: runtime?.inFlightCount ?? 0,
            cumulativeProcessedCount: runtime?.cumulativeProcessedCount ?? 0,
            scopeCount: max(progressRows(for: sourceKey).count, runtime?.queueDepth == nil ? 0 : 1),
            lastUpdatedAt: stats?.lastDocumentUpdatedAt ?? runtime?.updatedAt,
            currentOperation: runtime?.currentOperation.replacingOccurrences(of: "_", with: " ").capitalized ?? RetrievalOperationPayload.idle.rawValue.capitalized,
            currentItemPath: runtime?.currentItemPath,
            scanCandidatesSeen: runtime?.lastScanCandidatesSeen ?? 0,
            scanCandidatesSkippedExcluded: runtime?.lastScanCandidatesSkippedExcluded ?? 0,
            scanEventsEmitted: runtime?.lastScanEventsEmitted ?? 0,
            extractionSuccessCount: runtime?.extractionSuccessCount ?? 0,
            extractionPartialCount: runtime?.extractionPartialCount ?? 0,
            extractionFailedCount: runtime?.extractionFailedCount ?? 0,
            extractionUnsupportedCount: runtime?.extractionUnsupportedCount ?? 0,
            extractionOCRCount: runtime?.extractionOCRCount ?? 0
        )
    }

    func overallModel(enabled: Bool) -> RetrievalOverallDetailModel {
        let status = overallStatus(enabled: enabled)
        let state = snapshot
        let health = state?.health
        let queueActivity = state?.queueActivity
        let totalIndexedItems = state?.indexStats.totalDocumentCount ?? 0
        let runtimeRows = state?.sourceRuntime ?? []
        let indexedItemsThisRun = runtimeRows.reduce(0) { $0 + $1.cumulativeProcessedCount }
        let totalInFlight = runtimeRows.reduce(0) { $0 + $1.inFlightCount }
        let activeSourceCount = runtimeRows.filter { $0.queueDepth > 0 || $0.inFlightCount > 0 || $0.cumulativeProcessedCount > 0 }.count

        return RetrievalOverallDetailModel(
            status: status,
            totalIndexedItems: totalIndexedItems,
            indexedItemsThisRun: indexedItemsThisRun,
            totalQueuedItems: queueActivity?.queueDepth ?? health?.queueDepth ?? 0,
            totalInFlightItems: totalInFlight > 0 ? totalInFlight : (health?.inFlightCount ?? 0),
            activeSourceCount: activeSourceCount,
            currentOperation: state?.currentOperation.replacingOccurrences(of: "_", with: " ").capitalized ?? health?.currentOperation.replacingOccurrences(of: "_", with: " ").capitalized ?? RetrievalOperationPayload.idle.rawValue.capitalized,
            currentOperationSource: state?.currentOperationSourceType ?? health?.currentOperationSourceType,
            currentItemPath: state?.currentItemPath ?? health?.currentItemPath,
            lastUpdatedAt: state?.updatedAt ?? lastRefreshAt,
            extractionSuccessCount: health?.extractionSuccessCount ?? 0,
            extractionPartialCount: health?.extractionPartialCount ?? 0,
            extractionFailedCount: health?.extractionFailedCount ?? 0,
            extractionUnsupportedCount: health?.extractionUnsupportedCount ?? 0,
            extractionOCRCount: health?.extractionOCRCount ?? 0
        )
    }

    // MARK: - Polling

    private func startPollingIfNeeded() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshState()
            while !Task.isCancelled, self.pollingEnabled {
                let delaySeconds = self.nextPollingDelaySeconds()
                try? await Task.sleep(for: .milliseconds(Int(delaySeconds * 1_000)))
                await self.refreshState()
            }
        }
    }

    private func nextPollingDelaySeconds() -> Double {
        if consecutiveErrorCount > 0 {
            return min(20, pow(2, Double(consecutiveErrorCount)) * 1.2)
        }
        if isIndexingNow {
            return 3
        }
        return 4
    }

    private var isIndexingNow: Bool {
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

    private func refreshState() async {
        guard pollingEnabled else { return }
        guard !isRefreshing else { return } 
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let token = try RetrievalDaemonManager.shared.daemonAuthToken()
            let baseURL = RetrievalDaemonManager.shared.daemonBaseURL()
            var request = URLRequest(url: baseURL.appending(path: "api/v1/retrieval/state"))
            request.setValue(token, forHTTPHeaderField: "X-Retrieval-Token")
            request.timeoutInterval = 3
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw NSError(
                    domain: "RetrievalIndex",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Retrieval state endpoint returned a non-success status."]
                )
            }
            let decoder = JSONDecoder()
            let payload = try decoder.decode(RetrievalStatePayload.self, from: data)
            snapshot = payload
            fetchError = nil
            lastRefreshAt = Date()
            consecutiveErrorCount = 0
            allowlistRoots = RetrievalDaemonManager.shared.allowlistRootsForDisplay()
        } catch {
            fetchError = error.localizedDescription
            lastRefreshAt = Date()
            consecutiveErrorCount += 1
            allowlistRoots = RetrievalDaemonManager.shared.allowlistRootsForDisplay()
        }
    }

    // MARK: - State Derivation

    private func overallStatus(enabled: Bool) -> RetrievalIndexStatusKind {
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

    private func sourceStatus(for sourceKey: String, enabled: Bool) -> RetrievalIndexStatusKind {
        guard enabled else { return .disabled }
        guard let snapshot else { return .unavailable }
        if let error = snapshot.health.lastError, !error.isEmpty {
            return .needsAttention
        }
        guard snapshot.health.running else { return .unavailable }
        let runtime = runtimeRow(for: sourceKey)
        let progressRows = progressRows(for: sourceKey)
        let checkpointTerminal = progressRows.allSatisfy { isTerminalCheckpointStatus($0.status) }
        let indexed = statsRow(for: sourceKey)?.documentCount ?? 0
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

    private func runtimeRow(for sourceKey: String) -> RetrievalSourceRuntimePayload? {
        snapshot?.sourceRuntime.first(where: { $0.sourceType.lowercased() == sourceKey.lowercased() })
    }

    private func statsRow(for sourceKey: String) -> RetrievalSourceStatsPayload? {
        snapshot?.indexStats.sources.first(where: { $0.sourceType.lowercased() == sourceKey.lowercased() })
    }

    private func progressRows(for sourceKey: String) -> [RetrievalProgressPayload] {
        (snapshot?.progress ?? []).filter { $0.sourceType.lowercased() == sourceKey.lowercased() }
    }

    private func isTerminalCheckpointStatus(_ status: String) -> Bool {
        let normalized = status.lowercased()
        return normalized == "idle" || normalized == "completed" || normalized == "complete" || normalized == "paused"
    }

    private func emptySourceDetail(entry: RetrievalSidebarEntry, status: RetrievalIndexStatusKind) -> RetrievalSourceDetailModel {
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
}

// MARK: - Payloads

private struct RetrievalStatePayload: Decodable {
    let health: RetrievalHealthPayloadV2
    let progress: [RetrievalProgressPayload]
    let indexStats: RetrievalIndexStatsPayloadV2
    let queueActivity: RetrievalQueueActivityPayloadV2
    let sourceRuntime: [RetrievalSourceRuntimePayload]
    let currentOperation: String
    let currentOperationSourceType: String?
    let currentItemPath: String?
    let updatedAt: Date
}

private struct RetrievalHealthPayloadV2: Decodable {
    let daemonVersion: String?
    let running: Bool
    let queueDepth: Int
    let inFlightCount: Int
    let lastError: String?
    let currentOperation: String
    let currentOperationSourceType: String?
    let currentItemPath: String?
    let extractionSuccessCount: Int
    let extractionPartialCount: Int
    let extractionFailedCount: Int
    let extractionUnsupportedCount: Int
    let extractionOCRCount: Int
}

private struct RetrievalProgressPayload: Decodable {
    let sourceType: String
    let scopeLabel: String
    let status: String
    let itemsProcessed: Int
    let itemsSkipped: Int
    let estimatedTotal: Int
    let percentComplete: Double
    let etaSeconds: Int?
    let checkpointUpdatedAt: Date
}

private struct RetrievalSourceStatsPayload: Decodable {
    let sourceType: String
    let documentCount: Int
    let lastDocumentUpdatedAt: Date?
}

private struct RetrievalIndexStatsPayloadV2: Decodable {
    let totalDocumentCount: Int
    let sources: [RetrievalSourceStatsPayload]
}

private struct RetrievalQueueSourcePayload: Decodable {
    let sourceType: String
    let queuedItemCount: Int
}

private struct RetrievalQueueActivityPayloadV2: Decodable {
    let queueDepth: Int
    let sources: [RetrievalQueueSourcePayload]
}

private struct RetrievalSourceRuntimePayload: Decodable {
    let sourceType: String
    let queueDepth: Int
    let inFlightCount: Int
    let cumulativeProcessedCount: Int
    let extractionSuccessCount: Int
    let extractionPartialCount: Int
    let extractionFailedCount: Int
    let extractionUnsupportedCount: Int
    let extractionOCRCount: Int
    let lastScanCandidatesSeen: Int
    let lastScanCandidatesSkippedExcluded: Int
    let lastScanEventsEmitted: Int
    let lastScanAt: Date?
    let currentOperation: String
    let currentItemPath: String?
    let updatedAt: Date
}

private enum RetrievalOperationPayload: String {
    case idle
    case scanning
    case extracting
    case ingesting
    case backfilling
}
