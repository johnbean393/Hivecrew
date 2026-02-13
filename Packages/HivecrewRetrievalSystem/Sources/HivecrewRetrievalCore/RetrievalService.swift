import CryptoKit
import Darwin
import Foundation
import HivecrewRetrievalProtocol
#if canImport(IOKit.ps)
import IOKit.ps
#endif

public actor RetrievalService {
    private let daemonVersion: String
    private let configuration: RetrievalDaemonConfiguration
    private let store: RetrievalStore
    private let policy: IndexingPolicy
    private let connectorHub: ConnectorHub
    private let extractionService: ContentExtractionService
    private let queryEmbeddingRuntime: EmbeddingRuntime
    private let ingestionEmbeddingRuntimes: [EmbeddingRuntime]
    private let searchEngine: HybridSearchEngine
    private let packAssembler: ContextPackAssembler
    private let metrics: RetrievalMetrics
    private let graphAugmentor: GraphAugmentor
    private let reranker: LocalReranker

    private var queue: [IngestionEvent] = []
    private var queueCounts: [RetrievalSourceType: Int] = [:]
    private var queueTask: Task<Void, Never>?
    private var ingestionWorkerTasks: [UUID: Task<Void, Never>] = [:]
    private var ingestionWorkerPriority: TaskPriority = .utility
    private var compactTask: Task<Void, Never>?
    private var startupBackfillTask: Task<Void, Never>?
    private var suggestCache: [String: (Date, RetrievalSuggestResponse)] = [:]
    private var lastSuggestionsByQuery: [String: [RetrievalSuggestion]] = [:]
    private var connectorsRegistered = false
    private var isRunning = false
    private var isSleepPaused = false
    private var startupBackfillCompleted = false
    private static let cachedEfficiencyCoreCount: Int = {
        if let count = cpuCount(sysctlName: "hw.perflevel1.physicalcpu"), count > 0 {
            return count
        }
        // Fallback: assume a heterogeneous split if perflevel counters are unavailable.
        return max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
    }()
    private static let ingestionWorkerMultiplier = 1

    public init(configuration: RetrievalDaemonConfiguration, paths: RetrievalPaths) throws {
        self.daemonVersion = Self.computeDaemonVersion()
        self.configuration = configuration
        self.policy = IndexingPolicy.preset(
            profile: configuration.indexingProfile,
            startupAllowlistRoots: configuration.startupAllowlistRoots
        )
        let store = RetrievalStore(dbPath: paths.metadataDBPath, contextPackDirectory: paths.contextPacksDirectory)
        self.store = store
        self.connectorHub = ConnectorHub()
        self.extractionService = ContentExtractionService()
        let queryEmbeddingRuntime = EmbeddingRuntime()
        self.queryEmbeddingRuntime = queryEmbeddingRuntime
        let runtimeCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
        self.ingestionEmbeddingRuntimes = (0..<runtimeCount).map { _ in EmbeddingRuntime() }
        self.metrics = RetrievalMetrics()
        self.reranker = LocalReranker()
        self.graphAugmentor = GraphAugmentor(store: store)
        self.searchEngine = HybridSearchEngine(
            store: store,
            embeddingRuntime: queryEmbeddingRuntime,
            graphAugmentor: graphAugmentor,
            reranker: reranker
        )
        self.packAssembler = ContextPackAssembler(store: store)

    }

    public func start() async {
        if isRunning {
            if isSleepPaused {
                await resumeAfterSystemWake()
            }
            return
        }
        await ensureConnectorsRegistered()
        do {
            try await store.openAndMigrate()
            try await store.refreshFileSearchability(nonSearchableExtensions: policy.nonSearchableFileExtensions)
            _ = try await store.reclaimQueueSnapshotStorageIfNeeded()
        } catch {
            await metrics.recordError(error)
        }
        isRunning = true
        isSleepPaused = false
        await startRuntimePipelines(triggerStartupBackfill: true)
    }

    public func stop() async {
        guard isRunning || isSleepPaused else { return }
        queueTask?.cancel()
        queueTask = nil
        await stopIngestionWorkers()
        compactTask?.cancel()
        compactTask = nil
        startupBackfillTask?.cancel()
        startupBackfillTask = nil
        await connectorHub.stopAll()
        isRunning = false
        isSleepPaused = false
        startupBackfillCompleted = false
    }

    public func pauseForSystemSleep() async {
        guard isRunning, !isSleepPaused else { return }
        isSleepPaused = true
        queueTask?.cancel()
        queueTask = nil
        await stopIngestionWorkers()
        compactTask?.cancel()
        compactTask = nil
        startupBackfillTask?.cancel()
        startupBackfillTask = nil
        await connectorHub.stopAll()
    }

    public func resumeAfterSystemWake() async {
        guard isRunning, isSleepPaused else { return }
        isSleepPaused = false
        let needsStartupBackfill = !startupBackfillCompleted
        await startRuntimePipelines(triggerStartupBackfill: needsStartupBackfill)
    }

    public func authorize(token: String) throws {
        guard token == configuration.authToken else {
            throw RetrievalCoreError.unauthorized
        }
    }

    public func suggest(request: RetrievalSuggestRequest) async throws -> RetrievalSuggestResponse {
        let cacheKey = "\(request.query.lowercased())|\(request.typingMode)|\(request.limit)|\(request.sourceFilters?.map(\.rawValue).sorted().joined(separator: ",") ?? "all")"
        if let (cachedAt, response) = suggestCache[cacheKey], Date().timeIntervalSince(cachedAt) < 1.5 {
            return response
        }
        let response = try await searchEngine.suggest(request: request)
        suggestCache[cacheKey] = (Date(), response)
        lastSuggestionsByQuery[request.query] = response.suggestions
        await metrics.recordLatency(response.latencyMs)
        return response
    }

    public func createContextPack(request: RetrievalCreateContextPackRequest) async throws -> RetrievalContextPack {
        let suggestions = lastSuggestionsByQuery[request.query] ?? []
        let pack = try await packAssembler.build(request: request, availableSuggestions: suggestions)
        return pack
    }

    public func preview(itemId: String) async throws -> RetrievalSuggestion? {
        guard let doc = try await store.fetchDocument(for: itemId) else { return nil }
        return RetrievalSuggestion(
            id: doc.id,
            sourceType: doc.sourceType,
            title: doc.title,
            snippet: String(doc.body.prefix(1_200)),
            sourceId: doc.sourceId,
            sourcePathOrHandle: doc.sourcePathOrHandle,
            relevanceScore: 0,
            risk: doc.risk,
            reasons: ["preview"],
            timestamp: doc.updatedAt
        )
    }

    public func health() async -> RetrievalHealth {
        await metrics.setQueueState(totalDepth: queue.count, bySource: queueCounts)
        return await metrics.health(version: daemonVersion)
    }

    public func stateSnapshot() async throws -> RetrievalStateSnapshot {
        let bySource = queueCounts
        await metrics.setQueueState(totalDepth: queue.count, bySource: bySource)
        let health = await metrics.health(version: daemonVersion)
        let progress = try await store.allProgressStates()
        let stats = try await store.indexStats()
        let activitySources = RetrievalSourceType.allCases.map { sourceType in
            RetrievalQueueSourceActivity(sourceType: sourceType, queuedItemCount: bySource[sourceType] ?? 0)
        }
        let activity = RetrievalQueueActivity(queueDepth: queue.count, sources: activitySources)
        let runtime = await metrics.sourceRuntimeStates()
        let operation = await metrics.operationContext()
        return RetrievalStateSnapshot(
            health: health,
            progress: progress,
            indexStats: stats,
            queueActivity: activity,
            sourceRuntime: runtime,
            currentOperation: operation.phase,
            currentOperationSourceType: operation.sourceType,
            currentItemPath: operation.path
        )
    }

    public func indexingProgress() async throws -> [RetrievalProgressState] {
        try await store.allProgressStates()
    }

    public func indexStats() async throws -> RetrievalIndexStats {
        try await store.indexStats()
    }

    public func queueActivity() async -> RetrievalQueueActivity {
        let counts = queueCounts
        let sources = RetrievalSourceType.allCases.map { sourceType in
            RetrievalQueueSourceActivity(
                sourceType: sourceType,
                queuedItemCount: counts[sourceType] ?? 0
            )
        }
        return RetrievalQueueActivity(
            queueDepth: queue.count,
            sources: sources
        )
    }

    public func listBackfillJobs() async throws -> [RetrievalBackfillJob] {
        try await store.listBackfillJobs()
    }

    public func pauseBackfill(jobId: String) async {
        await connectorHub.pause(jobId: jobId)
    }

    public func resumeBackfill(jobId: String) async {
        await connectorHub.resume(jobId: jobId)
    }

    public func configureScopes(_ request: RetrievalConfigureScopesRequest) async throws {
        let payload = request.scopes.map {
            [
                "sourceType": $0.sourceType.rawValue,
                "enabled": $0.enabled.description,
                "includes": $0.includePathsOrHandles.joined(separator: "|"),
                "excludes": $0.excludePathsOrHandles.joined(separator: "|"),
            ]
        }
        for entry in payload {
            try await store.appendAudit(kind: "scope_configured", payload: entry)
        }
    }

    public func triggerBackfill(limit: Int = 50_000) async throws -> [BackfillCheckpoint] {
        await ensureConnectorsRegistered()
        var checkpoints: [BackfillCheckpoint] = []
        for source in RetrievalSourceType.allCases {
            await metrics.beginBackfill(sourceType: source)
            do {
                let key = "\(source.rawValue):default"
                let sourceLimit = source == .file ? max(limit, 50_000) : limit
                // File indexing policy evolves frequently (extensions, OCR support, extraction quality).
                // Always start file backfills from scratch so previously skipped files become eligible.
                let previous = source == .file ? nil : try await store.loadCheckpoint(key: key)?.resumeToken
                var resumeToken = previous
                var latestCheckpoint: BackfillCheckpoint?
                var iterations = 0
                while iterations < 64 {
                    let checkpoint = try await connectorHub.runBackfill(
                        source: source,
                        resumeToken: resumeToken,
                        policy: policy,
                        limit: sourceLimit
                    ) { events, checkpoint in
                        await self.enqueue(events: events)
                        try? await self.store.saveCheckpoint(checkpoint)
                        try? await self.store.upsertBackfillJob(
                            RetrievalBackfillJob(
                                id: key,
                                sourceType: source,
                                scopeLabel: checkpoint.scopeLabel,
                                status: checkpoint.status,
                                resumeToken: checkpoint.resumeToken
                            )
                        )
                    }
                    guard let checkpoint else { break }
                    latestCheckpoint = checkpoint
                    resumeToken = checkpoint.resumeToken
                    iterations += 1
                    if checkpoint.itemsProcessed < sourceLimit {
                        break
                    }
                }
                if let checkpoint = latestCheckpoint {
                    checkpoints.append(checkpoint)
                }
                await metrics.endBackfill(sourceType: source)
            } catch {
                await metrics.endBackfill(sourceType: source)
                throw error
            }
        }
        return checkpoints
    }

    public func runBenchmarkSample(queries: [String]) async throws -> [String: Int] {
        var results: [String: Int] = [:]
        for query in queries {
            let response = try await suggest(
                request: RetrievalSuggestRequest(
                    query: query,
                    sourceFilters: nil,
                    limit: 12,
                    typingMode: true,
                    includeColdPartitionFallback: true
                )
            )
            results[query] = response.latencyMs
        }
        return results
    }

    private func startRuntimePipelines(triggerStartupBackfill: Bool) async {
        queueTask?.cancel()
        await stopIngestionWorkers()
        queueTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.reconcileIngestionWorkers()
                try? await Task.sleep(for: .milliseconds(250))
            }
            await self.stopIngestionWorkers()
        }
        compactTask?.cancel()
        compactTask = Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8 * 3_600))
                try? await self.store.compact()
            }
        }

        await connectorHub.startAll { [weak self] events in
            await self?.enqueue(events: events)
        }

        if triggerStartupBackfill {
            scheduleStartupBackfill()
        }
    }

    private func scheduleStartupBackfill() {
        startupBackfillTask?.cancel()
        startupBackfillTask = Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            // Kick off full backfill on startup and retry a few times for resilience.
            var delayMs = 500
            for attempt in 0..<5 {
                if Task.isCancelled {
                    return
                }
                do {
                    _ = try await self.triggerBackfill(limit: 50_000)
                    await self.markStartupBackfillCompleted()
                    return
                } catch is CancellationError {
                    return
                } catch {
                    await self.metrics.recordError(error)
                    if attempt == 4 { return }
                    try? await Task.sleep(for: .milliseconds(delayMs))
                    delayMs *= 2
                }
            }
        }
    }

    private func markStartupBackfillCompleted() {
        startupBackfillCompleted = true
    }

    private func ensureConnectorsRegistered() async {
        guard !connectorsRegistered else { return }
        let fileConnector = FileConnector(
            policy: policy,
            scanStatsHandler: { [weak self] stats in
                await self?.handleScanBatchStats(stats)
            }
        )
        await connectorHub.register(fileConnector)
        await connectorHub.register(StubDeltaConnector(sourceType: .email))
        await connectorHub.register(StubDeltaConnector(sourceType: .message))
        await connectorHub.register(StubDeltaConnector(sourceType: .calendar))
        connectorsRegistered = true
    }

    private func handleScanBatchStats(_ stats: FileConnector.ScanBatchStats) async {
        await metrics.recordScanBatch(stats, sourceType: .file)
        try? await store.appendAudit(
            kind: "file_scan_batch",
            payload: [
                "mode": stats.mode,
                "rootsScanned": "\(stats.rootsScanned)",
                "candidatesSeen": "\(stats.candidatesSeen)",
                "candidatesSkippedExcluded": "\(stats.candidatesSkippedExcluded)",
                "eventsEmitted": "\(stats.eventsEmitted)",
            ]
        )
    }

    private func handleExtractionTelemetry(path: String, telemetry: ExtractionTelemetry) async {
        await metrics.recordExtraction(telemetry, sourceType: .file, path: path)
        var payload: [String: String] = [
            "path": path,
            "outcome": telemetry.outcome.rawValue,
            "format": telemetry.format,
            "usedOCR": telemetry.usedOCR.description,
        ]
        if let detail = telemetry.detail {
            payload["detail"] = detail
        }
        try? await store.appendAudit(kind: "file_extraction_\(telemetry.outcome.rawValue)", payload: payload)
    }

    private func enqueue(events: [IngestionEvent]) async {
        guard !events.isEmpty else { return }
        queue.append(contentsOf: events)
        for event in events {
            queueCounts[event.sourceType, default: 0] += 1
        }
        await metrics.setQueueState(totalDepth: queue.count, bySource: queueCounts)
    }

    private func reconcileIngestionWorkers() async {
        let desiredWorkerCount = targetIngestionWorkerCount()
        let desiredPriority = ingestionTaskPriority()
        if desiredPriority != ingestionWorkerPriority {
            await stopIngestionWorkers()
            ingestionWorkerPriority = desiredPriority
        }

        let currentWorkerCount = ingestionWorkerTasks.count
        if currentWorkerCount < desiredWorkerCount {
            for _ in currentWorkerCount..<desiredWorkerCount {
                spawnIngestionWorker(priority: desiredPriority)
            }
        } else if currentWorkerCount > desiredWorkerCount {
            let overflow = currentWorkerCount - desiredWorkerCount
            for id in Array(ingestionWorkerTasks.keys.prefix(overflow)) {
                ingestionWorkerTasks[id]?.cancel()
                ingestionWorkerTasks.removeValue(forKey: id)
            }
        }
    }

    private func spawnIngestionWorker(priority: TaskPriority) {
        let workerID = UUID()
        let task = Task.detached(priority: priority) { [weak self] in
            guard let self else { return }
            defer {
                Task {
                    await self.ingestionWorkerDidFinish(workerID: workerID)
                }
            }
            while !Task.isCancelled {
                guard let event = await self.dequeueNextEvent() else {
                    try? await Task.sleep(for: .milliseconds(50))
                    continue
                }
                let activeWorkerCount = await self.currentIngestionWorkerCount()
                await self.ingestSingleEvent(event, activeWorkerCount: activeWorkerCount)
            }
        }
        ingestionWorkerTasks[workerID] = task
    }

    private func dequeueNextEvent() async -> IngestionEvent? {
        guard !queue.isEmpty else {
            return nil
        }
        let event = queue.removeFirst()
        if let current = queueCounts[event.sourceType] {
            let next = current - 1
            if next > 0 {
                queueCounts[event.sourceType] = next
            } else {
                queueCounts.removeValue(forKey: event.sourceType)
            }
        }
        await metrics.setQueueState(totalDepth: queue.count, bySource: queueCounts)
        return event
    }

    private func currentIngestionWorkerCount() -> Int {
        max(1, ingestionWorkerTasks.count)
    }

    private func ingestionWorkerDidFinish(workerID: UUID) {
        ingestionWorkerTasks.removeValue(forKey: workerID)
    }

    private func stopIngestionWorkers() async {
        for task in ingestionWorkerTasks.values {
            task.cancel()
        }
        ingestionWorkerTasks.removeAll()
    }

    private func ingestSingleEvent(_ event: IngestionEvent, activeWorkerCount: Int) async {
        await metrics.beginIngestion(sourceType: event.sourceType, path: event.sourcePathOrHandle)
        do {
            let isCurrent = try await store.isDocumentCurrent(
                sourceType: event.sourceType,
                sourceId: event.sourceId,
                updatedAt: event.occurredAt
            )
            if isCurrent {
                await metrics.endIngestion(sourceType: event.sourceType, path: event.sourcePathOrHandle, success: true)
                return
            }
        } catch {
            await metrics.recordError(error)
        }
        guard let payload = await resolveIngestionPayload(for: event) else {
            await metrics.endIngestion(sourceType: event.sourceType, path: event.sourcePathOrHandle, success: true)
            return
        }
        let documentID = documentID(for: event)
        let searchable = shouldIncludeInSearch(for: event)
        let doc = RetrievalDocument(
            id: documentID,
            sourceType: event.sourceType,
            sourceId: event.sourceId,
            title: payload.title,
            body: RedactionService().redact(payload.body),
            sourcePathOrHandle: event.sourcePathOrHandle,
            updatedAt: event.occurredAt,
            risk: inferRisk(forBody: payload.body),
            partition: inferPartition(for: event.occurredAt),
            searchable: searchable
        )
        // Persist the document record immediately after successful extraction so
        // index stats reflect progress before heavier embedding/chunk steps finish.
        do {
            try await store.upsertDocumentRecord(doc)
            await metrics.recordDocumentPersisted(sourceType: event.sourceType, path: event.sourcePathOrHandle)
        } catch {
            await metrics.endIngestion(sourceType: event.sourceType, path: event.sourcePathOrHandle, success: false)
            await metrics.recordError(error)
            return
        }
        let rawChunks = searchable
            ? splitIntoChunks(payload.body, maxChunks: policy.maxChunksPerDocument, chunkSize: 1_000)
            : []
        var chunkEmbeddings: [[Float]] = []
        if searchable, !rawChunks.isEmpty {
            do {
                let runtime = embeddingRuntimeForDocument(documentID, activeWorkerCount: activeWorkerCount)
                let (values, _) = try await runtime.embed(texts: rawChunks)
                chunkEmbeddings = values
            } catch {
                await metrics.recordError(error)
                await metrics.endIngestion(sourceType: event.sourceType, path: event.sourcePathOrHandle, success: false)
                return
            }
        }

        do {
            var chunks: [RetrievalChunk] = []
            for chunkIndex in rawChunks.indices {
                chunks.append(
                    RetrievalChunk(
                        id: "\(documentID):\(chunkIndex)",
                        documentId: documentID,
                        text: rawChunks[chunkIndex],
                        index: chunkIndex,
                        embedding: chunkEmbeddings[safe: chunkIndex] ?? []
                    )
                )
            }
            try await store.upsertDocument(doc, chunks: chunks)
            if searchable {
                try await store.insertGraphEdges(buildGraphEdges(for: doc))
            }
            await metrics.endIngestion(sourceType: event.sourceType, path: event.sourcePathOrHandle, success: true)
        } catch {
            await metrics.endIngestion(sourceType: event.sourceType, path: event.sourcePathOrHandle, success: false)
            await metrics.recordError(error)
        }
    }

    private func resolveIngestionPayload(for event: IngestionEvent) async -> (title: String, body: String)? {
        if event.sourceType == .file {
            let url = URL(fileURLWithPath: event.sourcePathOrHandle)
            let result = await extractionService.extract(fileURL: url, policy: policy)
            await handleExtractionTelemetry(path: event.sourcePathOrHandle, telemetry: result.telemetry)
            guard let content = result.content else {
                return nil
            }
            let trimmed = content.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return nil
            }
            return (content.title ?? event.title, trimmed)
        }
        let trimmed = event.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        return (event.title, trimmed)
    }

    private func splitIntoChunks(_ text: String, maxChunks: Int, chunkSize: Int) -> [String] {
        if text.isEmpty {
            return []
        }
        var chunks: [String] = []
        var cursor = text.startIndex
        while cursor < text.endIndex && chunks.count < maxChunks {
            let next = text.index(cursor, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[cursor..<next]))
            cursor = next
        }
        return chunks
    }

    private func inferRisk(forBody body: String) -> RetrievalRiskLabel {
        let body = body.lowercased()
        if body.contains("password") || body.contains("secret") || body.contains("api key") {
            return .high
        }
        if body.contains("ssn") || body.contains("bank") || body.contains("private") {
            return .medium
        }
        return .low
    }

    private func shouldIncludeInSearch(for event: IngestionEvent) -> Bool {
        guard event.sourceType == .file else {
            return true
        }
        let ext = URL(fileURLWithPath: event.sourcePathOrHandle).pathExtension.lowercased()
        if ext.isEmpty {
            return true
        }
        return !policy.nonSearchableFileExtensions.contains(ext)
    }

    private func documentID(for event: IngestionEvent) -> String {
        let input = "\(event.sourceType.rawValue)|\(event.sourceId)"
        let digest = SHA256.hash(data: Data(input.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "doc_\(hex.prefix(24))"
    }

    private func targetIngestionWorkerCount() -> Int {
        let allCores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let batteryMode = Self.isRunningOnBatteryPower() || ProcessInfo.processInfo.isLowPowerModeEnabled
        let baseWorkerCount: Int
        if batteryMode {
            baseWorkerCount = max(1, min(allCores, Self.cachedEfficiencyCoreCount))
        } else {
            baseWorkerCount = allCores
        }
        return max(1, baseWorkerCount * Self.ingestionWorkerMultiplier)
    }

    private func embeddingRuntimeForDocument(_ documentID: String, activeWorkerCount: Int) -> EmbeddingRuntime {
        let available = max(1, min(activeWorkerCount, ingestionEmbeddingRuntimes.count))
        var hasher = Hasher()
        hasher.combine(documentID)
        let hash = hasher.finalize()
        let index = Int(UInt(bitPattern: hash) % UInt(available))
        return ingestionEmbeddingRuntimes[index]
    }

    private func ingestionTaskPriority() -> TaskPriority {
        let batteryMode = Self.isRunningOnBatteryPower() || ProcessInfo.processInfo.isLowPowerModeEnabled
        return batteryMode ? .utility : .userInitiated
    }

    private static func isRunningOnBatteryPower() -> Bool {
        #if canImport(IOKit.ps)
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        guard let sourceType = IOPSGetProvidingPowerSourceType(info)?
            .takeUnretainedValue() as String?
        else {
            return false
        }
        return sourceType == kIOPSBatteryPowerValue
        #else
        return false
        #endif
    }

    private static func cpuCount(sysctlName: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let status = sysctlbyname(sysctlName, &value, &size, nil, 0)
        guard status == 0 else { return nil }
        return Int(value)
    }

    private static func computeDaemonVersion() -> String {
        guard let executablePath = CommandLine.arguments.first else {
            return "unknown"
        }
        let executableURL = URL(fileURLWithPath: executablePath)
        guard let data = try? Data(contentsOf: executableURL, options: .mappedIfSafe) else {
            return "unknown"
        }
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }

    private func inferPartition(for updatedAt: Date) -> String {
        let age = Date().timeIntervalSince(updatedAt)
        if age < 86_400 * 30 { return "hot" }
        if age < 86_400 * 180 { return "warm" }
        return "cold"
    }

    private func buildGraphEdges(for document: RetrievalDocument) -> [GraphEdge] {
        let tokens = Set(
            document.body
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "@" && $0 != "." })
                .map(String.init)
                .filter { $0.count > 3 }
                .prefix(10)
        )
        return tokens.map { token in
            GraphEdge(
                id: "\(document.id):mentions:\(token.lowercased())",
                sourceNode: document.id,
                targetNode: token.lowercased(),
                edgeType: "mentions",
                confidence: 0.6,
                weight: 1.0,
                sourceType: document.sourceType,
                eventTime: document.updatedAt,
                updatedAt: Date()
            )
        }
    }
}
