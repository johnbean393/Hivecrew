import CoreServices
import Foundation
import HivecrewRetrievalProtocol
import UniformTypeIdentifiers

public final class FileConnector: SourceConnector, @unchecked Sendable {
    public struct ScanBatchStats: Sendable, Codable {
        public let mode: String
        public let rootsScanned: Int
        public let candidatesSeen: Int
        public let candidatesSkippedExcluded: Int
        public let eventsEmitted: Int
        public let occurredAt: Date

        public init(
            mode: String,
            rootsScanned: Int,
            candidatesSeen: Int,
            candidatesSkippedExcluded: Int,
            eventsEmitted: Int,
            occurredAt: Date = Date()
        ) {
            self.mode = mode
            self.rootsScanned = rootsScanned
            self.candidatesSeen = candidatesSeen
            self.candidatesSkippedExcluded = candidatesSkippedExcluded
            self.eventsEmitted = eventsEmitted
            self.occurredAt = occurredAt
        }
    }

    public let sourceType: RetrievalSourceType = .file
    private let policy: IndexingPolicy
    private let scanStatsHandler: (@Sendable (ScanBatchStats) async -> Void)?
    private var eventStream: FSEventStreamRef?
    private let callbackQueue = DispatchQueue(label: "com.hivecrew.retrieval.file-events", qos: .utility)
    private let stateQueue = DispatchQueue(label: "com.hivecrew.retrieval.file-events.state")
    private var pendingChangedPaths: Set<String> = []
    private var pendingOverflowed = false
    private var lastSeenEventID: FSEventStreamEventId?
    private var quietWindowTimer: DispatchSourceTimer?
    private var quietWindowGeneration: UInt64 = 0
    private var lastChangeFlushAt: Date = .distantPast
    private var liveHandler: (@Sendable ([IngestionEvent]) async -> Void)?
    private static let packageDirectoryExtensions: Set<String> = ["rtfd", "pages", "key", "numbers"]
    private static let maxPendingChangedPaths = 2_000
    private static let overflowRecoveryScanLimit = 384
    private static let maxDirectEventsPerFlush = 512
    private enum ScanMode {
        case changesSince
        case olderThanResumeToken
    }
    private struct ResumeCursor {
        let timestamp: TimeInterval
        let path: String?
    }

    public init(
        policy: IndexingPolicy,
        scanStatsHandler: (@Sendable (ScanBatchStats) async -> Void)? = nil
    ) {
        self.policy = policy
        self.scanStatsHandler = scanStatsHandler
    }

    public func start(handler: @escaping @Sendable ([IngestionEvent]) async -> Void) {
        stop()
        liveHandler = handler
        stateQueue.sync {
            pendingChangedPaths.removeAll(keepingCapacity: true)
            pendingOverflowed = false
            lastChangeFlushAt = Date()
        }

        // FSEvents for near-real-time updates and event-log reconciliation.
        startFSEvents()
    }

    public func stop() {
        stateQueue.sync {
            quietWindowGeneration &+= 1
            quietWindowTimer?.setEventHandler {}
            quietWindowTimer?.cancel()
            quietWindowTimer = nil
            pendingChangedPaths.removeAll(keepingCapacity: true)
            pendingOverflowed = false
        }
        stopFSEvents()
        liveHandler = nil
    }

    public func runBackfill(
        resumeToken: String?,
        mode: SourceBackfillMode,
        policy: IndexingPolicy,
        limit: Int,
        handler: @escaping @Sendable ([IngestionEvent], BackfillCheckpoint) async -> Void
    ) async throws -> BackfillCheckpoint? {
        let cursor = decodeResumeCursor(resumeToken)
        let tokenDate = cursor.map { Date(timeIntervalSince1970: $0.timestamp) } ?? resumeToken.flatMap { ISO8601DateFormatter().date(from: $0) }
        let scanMode: ScanMode = mode == .incremental ? .changesSince : .olderThanResumeToken
        let scanOutput = try await scanRecent(
            policy: policy,
            since: tokenDate,
            resumeCursor: mode == .incremental ? nil : cursor,
            limit: limit,
            mode: scanMode
        )
        let batch = scanOutput.events
        let candidateCount = scanOutput.selectedCandidateCount
        if mode == .full, candidateCount == 0 {
            return nil
        }
        let isIdle = candidateCount < limit
        let estimatedTotal = isIdle ? max(1, candidateCount) : max(limit, candidateCount)
        let resumeTokenValue: String? = {
            switch mode {
            case .full:
                return scanOutput.oldestCandidate.map { candidate in
                    encodeResumeCursor(timestamp: candidate.modifiedAt.timeIntervalSince1970, path: candidate.url.path)
                } ?? resumeToken
            case .incremental:
                if let newest = scanOutput.newestCandidate {
                    return encodeResumeCursor(timestamp: newest.modifiedAt.timeIntervalSince1970, path: newest.url.path)
                }
                if let resumeToken {
                    return resumeToken
                }
                return encodeResumeCursor(timestamp: Date().timeIntervalSince1970, path: "")
            }
        }()
        let checkpoint = BackfillCheckpoint(
            key: "file:default",
            sourceType: .file,
            scopeLabel: "default",
            cursor: nil,
            lastIndexedPath: batch.last?.sourcePathOrHandle ?? scanOutput.oldestCandidate?.url.path,
            lastIndexedTimestamp: batch.last?.occurredAt ?? scanOutput.oldestCandidate?.modifiedAt,
            resumeToken: resumeTokenValue,
            itemsProcessed: candidateCount,
            itemsSkipped: max(0, candidateCount - batch.count),
            estimatedTotal: estimatedTotal,
            status: isIdle ? "idle" : "running"
        )
        await handler(batch, checkpoint)
        return checkpoint
    }

    private func startFSEvents() {
        stopFSEvents()
        guard !policy.allowlistRoots.isEmpty else { return }
        let sinceWhen = stateQueue.sync { () -> FSEventStreamEventId in
            if let lastSeenEventID {
                return lastSeenEventID
            }
            let baseline = FSEventsGetCurrentEventId()
            lastSeenEventID = baseline
            return baseline
        }

        var context = FSEventStreamContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, eventCount, eventPathsPointer, _, eventIDsPointer in
            guard let info else {
                return
            }

            let connector = Unmanaged<FileConnector>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPathsPointer, to: NSArray.self) as? [String] ?? []
            let latestEventID: FSEventStreamEventId? = eventCount > 0
                ? UnsafeBufferPointer(start: eventIDsPointer, count: Int(eventCount)).max()
                : nil
            connector.enqueueChanged(
                paths: Array(paths.prefix(Int(eventCount))),
                latestEventID: latestEventID
            )
        }

        let roots = policy.allowlistRoots as CFArray
        let latency = max(0.4, min(policy.quietWindowSeconds, 4.0))
        let eventFlags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagUseCFTypes |
                kFSEventStreamCreateFlagIgnoreSelf |
                kFSEventStreamCreateFlagMarkSelf
        )
        let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            roots,
            sinceWhen,
            latency,
            eventFlags
        )
        guard let stream else { return }
        eventStream = stream
        FSEventStreamSetDispatchQueue(stream, callbackQueue)
        FSEventStreamStart(stream)
    }

    private func stopFSEvents() {
        guard let stream = eventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        eventStream = nil
    }

    private func enqueueChanged(paths: [String], latestEventID: FSEventStreamEventId? = nil) {
        stateQueue.sync {
            if let latestEventID {
                lastSeenEventID = max(lastSeenEventID ?? latestEventID, latestEventID)
            }
            for path in paths {
                guard isInsideAllowlistRoots(path) else { continue }
                guard !shouldSkipExcludedPath(path, policy: policy) else { continue }
                pendingChangedPaths.insert(path)
                if pendingChangedPaths.count > Self.maxPendingChangedPaths {
                    pendingChangedPaths.removeAll(keepingCapacity: true)
                    pendingOverflowed = true
                    break
                }
            }
            quietWindowGeneration &+= 1
            scheduleQuietWindowFlushLocked(afterSeconds: policy.quietWindowSeconds)
        }
    }

    private func scheduleQuietWindowFlushLocked(afterSeconds delay: TimeInterval) {
        ensureQuietWindowTimerLocked()
        let delayMs = max(1, Int((delay * 1_000).rounded(.up)))
        quietWindowTimer?.schedule(
            deadline: .now() + .milliseconds(delayMs),
            repeating: .never,
            leeway: .milliseconds(100)
        )
    }

    private func ensureQuietWindowTimerLocked() {
        guard quietWindowTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: callbackQueue)
        timer.setEventHandler { [weak self] in
            self?.handleQuietWindowTimerFire()
        }
        timer.resume()
        quietWindowTimer = timer
    }

    private func handleQuietWindowTimerFire() {
        let generation = stateQueue.sync { quietWindowGeneration }
        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            let isLatestGeneration = self.stateQueue.sync { self.quietWindowGeneration == generation }
            guard isLatestGeneration else { return }
            await self.flushPendingChanges()
        }
    }

    private func flushPendingChanges() async {
        let pending = stateQueue.sync { () -> (paths: [String], overflowed: Bool, previousFlushAt: Date) in
            let paths = Array(pendingChangedPaths)
            pendingChangedPaths.removeAll()
            let overflowed = pendingOverflowed
            pendingOverflowed = false
            let previousFlushAt = lastChangeFlushAt
            lastChangeFlushAt = Date()
            return (paths, overflowed, previousFlushAt)
        }

        if pending.overflowed {
            let sinceDate = pending.previousFlushAt == .distantPast ? nil : pending.previousFlushAt
            do {
                let scanOutput = try await scanRecent(
                    policy: policy,
                    since: sinceDate,
                    limit: Self.overflowRecoveryScanLimit,
                    mode: .changesSince
                )
                guard !scanOutput.events.isEmpty else { return }
                if let liveHandler {
                    await liveHandler(scanOutput.events)
                }
            } catch {
                print("FileConnector: overflow recovery scan failed: \(error.localizedDescription)")
            }
            return
        }

        var changed = pending.paths
        guard !changed.isEmpty else { return }
        if changed.count > Self.maxDirectEventsPerFlush {
            changed = Array(changed.prefix(Self.maxDirectEventsPerFlush))
        }

        let fm = FileManager.default
        var events: [IngestionEvent] = []
        events.reserveCapacity(changed.count)

        for path in changed {
            let scope = scopeLabel(for: path)
            if !fm.fileExists(atPath: path) {
                events.append(
                    IngestionEvent(
                        operation: .delete,
                        sourceType: .file,
                        scopeLabel: scope,
                        sourceId: path,
                        title: URL(fileURLWithPath: path).lastPathComponent,
                        body: "",
                        sourcePathOrHandle: path,
                        occurredAt: Date()
                    )
                )
                continue
            }
            let url = URL(fileURLWithPath: path)
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            guard isIndexableNode(url: url, values: values) else {
                continue
            }
            let attrs = try? fm.attributesOfItem(atPath: path)
            let modifiedAt = attrs?[.modificationDate] as? Date ?? Date()
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            if let event = buildIngestionEvent(
                url: url,
                modifiedAt: modifiedAt,
                fileSize: size,
                scope: scope,
                policy: policy
            ) {
                events.append(event)
            }
        }
        guard !events.isEmpty else { return }
        if let liveHandler {
            await liveHandler(events)
        }
    }

    private func scopeLabel(for path: String) -> String {
        let canonicalPath = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        for root in policy.allowlistRoots {
            let canonicalRoot = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
            guard canonicalPath == canonicalRoot || canonicalPath.hasPrefix(canonicalRoot + "/") else {
                continue
            }
            return URL(fileURLWithPath: root).lastPathComponent
        }
        return "default"
    }

    private func isInsideAllowlistRoots(_ path: String) -> Bool {
        let canonicalPath = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        for root in policy.allowlistRoots {
            let canonicalRoot = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
            if canonicalPath == canonicalRoot || canonicalPath.hasPrefix(canonicalRoot + "/") {
                return true
            }
        }
        return false
    }

    private func scanRecent(
        policy: IndexingPolicy,
        since: Date? = nil,
        resumeCursor: ResumeCursor? = nil,
        limit: Int = 128,
        mode: ScanMode = .changesSince
    ) async throws -> ScanRecentOutput {
        let candidateOutput = collectRecentCandidates(
            policy: policy,
            since: since,
            resumeCursor: resumeCursor,
            limit: limit,
            mode: mode
        )
        let candidates = candidateOutput.candidates
        var events: [IngestionEvent] = []
        for candidate in candidates {
            if let event = buildIngestionEvent(
                url: candidate.url,
                modifiedAt: candidate.modifiedAt,
                fileSize: candidate.size,
                scope: candidate.scope,
                policy: policy
            ) {
                events.append(event)
            }
        }
        let sorted = events.sorted { $0.occurredAt > $1.occurredAt }
        let stats = ScanBatchStats(
            mode: modeString(mode),
            rootsScanned: candidateOutput.rootsScanned,
            candidatesSeen: candidateOutput.candidatesSeen,
            candidatesSkippedExcluded: candidateOutput.candidatesSkippedExcluded,
            eventsEmitted: sorted.count
        )
        await reportScanStats(stats)
        return ScanRecentOutput(
            events: sorted,
            stats: stats,
            selectedCandidateCount: candidates.count,
            newestCandidate: candidates.first,
            oldestCandidate: candidates.last
        )
    }

    private struct ScanRecentOutput {
        let events: [IngestionEvent]
        let stats: ScanBatchStats
        let selectedCandidateCount: Int
        let newestCandidate: FileCandidate?
        let oldestCandidate: FileCandidate?
    }

    private struct FileCandidate {
        let url: URL
        let modifiedAt: Date
        let size: Int64
        let scope: String
    }

    private struct CandidateCollectionOutput {
        let candidates: [FileCandidate]
        let rootsScanned: Int
        let candidatesSeen: Int
        let candidatesSkippedExcluded: Int
    }

    private func collectRecentCandidates(
        policy: IndexingPolicy,
        since: Date?,
        resumeCursor: ResumeCursor?,
        limit: Int,
        mode: ScanMode
    ) -> CandidateCollectionOutput {
        guard limit > 0 else {
            return CandidateCollectionOutput(
                candidates: [],
                rootsScanned: 0,
                candidatesSeen: 0,
                candidatesSkippedExcluded: 0
            )
        }
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .isDirectoryKey]
        var candidates: [FileCandidate] = []
        candidates.reserveCapacity(limit)
        var weakestCandidateIndex = 0
        var rootsScanned = 0
        var candidatesSeen = 0
        var candidatesSkippedExcluded = 0

        for root in policy.allowlistRoots {
            let rootURL = URL(fileURLWithPath: root, isDirectory: true)
            rootsScanned += 1
            guard let enumerator = fm.enumerator(
                at: rootURL,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles],
                errorHandler: nil
            ) else {
                continue
            }
            for case let url as URL in enumerator {
                candidatesSeen += 1
                let values = try? url.resourceValues(forKeys: Set(keys))
                if shouldSkipExcludedPath(url.path, policy: policy) {
                    candidatesSkippedExcluded += 1
                    if values?.isDirectory == true {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                guard isIndexableNode(url: url, values: values) else { continue }
                let modifiedAt = values?.contentModificationDate ?? .distantPast
                if let since {
                    switch mode {
                    case .changesSince:
                        if modifiedAt <= since { continue }
                    case .olderThanResumeToken:
                        if modifiedAt >= since { continue }
                    }
                }
                if mode == .olderThanResumeToken,
                    let resumeCursor,
                    !isBeforeResumeCursor(modifiedAt: modifiedAt, path: url.path, cursor: resumeCursor)
                {
                    continue
                }
                let size = Int64(values?.fileSize ?? 0)
                switch policy.evaluate(fileURL: url, fileSize: size, modifiedAt: modifiedAt) {
                case .index, .deferred:
                    break
                case .skip:
                    continue
                }
                let candidate = FileCandidate(
                    url: url,
                    modifiedAt: modifiedAt,
                    size: size,
                    scope: rootURL.lastPathComponent
                )
                if candidates.count < limit {
                    candidates.append(candidate)
                    if candidates.count == 1 || isCandidateNewer(candidates[weakestCandidateIndex], than: candidate) {
                        weakestCandidateIndex = candidates.count - 1
                    }
                } else if isCandidateNewer(candidate, than: candidates[weakestCandidateIndex]) {
                    candidates[weakestCandidateIndex] = candidate
                    weakestCandidateIndex = weakestCandidateIndexForSelection(candidates)
                }
            }
        }
        _ = mode
        candidates.sort(by: isCandidateNewer(_:than:))
        return CandidateCollectionOutput(
            candidates: candidates,
            rootsScanned: rootsScanned,
            candidatesSeen: candidatesSeen,
            candidatesSkippedExcluded: candidatesSkippedExcluded
        )
    }

    private func isCandidateNewer(_ lhs: FileCandidate, than rhs: FileCandidate) -> Bool {
        if lhs.modifiedAt != rhs.modifiedAt {
            return lhs.modifiedAt > rhs.modifiedAt
        }
        return lhs.url.path > rhs.url.path
    }

    private func weakestCandidateIndexForSelection(_ candidates: [FileCandidate]) -> Int {
        guard !candidates.isEmpty else { return 0 }
        var weakestIndex = 0
        for index in candidates.indices.dropFirst() {
            if isCandidateNewer(candidates[weakestIndex], than: candidates[index]) {
                weakestIndex = index
            }
        }
        return weakestIndex
    }

    private func isIndexableNode(url: URL, values: URLResourceValues?) -> Bool {
        if values?.isRegularFile == true {
            return true
        }
        if values?.isDirectory == true {
            return Self.packageDirectoryExtensions.contains(url.pathExtension.lowercased())
        }
        return false
    }

    private func buildIngestionEvent(
        url: URL,
        modifiedAt: Date,
        fileSize: Int64,
        scope: String,
        policy: IndexingPolicy
    ) -> IngestionEvent? {
        switch policy.evaluate(fileURL: url, fileSize: fileSize, modifiedAt: modifiedAt) {
        case .index, .deferred:
            return IngestionEvent(
                sourceType: .file,
                scopeLabel: scope,
                sourceId: url.path,
                title: url.lastPathComponent,
                body: "",
                sourcePathOrHandle: url.path,
                occurredAt: modifiedAt
            )
        case .skip:
            return nil
        }
    }

    private func reportScanStats(_ stats: ScanBatchStats) async {
        guard let scanStatsHandler else {
            return
        }
        await scanStatsHandler(stats)
    }

    private func shouldSkipExcludedPath(_ path: String, policy: IndexingPolicy) -> Bool {
        policy.shouldSkipPath(path)
    }

    private func modeString(_ mode: ScanMode) -> String {
        switch mode {
        case .changesSince:
            return "changes_since"
        case .olderThanResumeToken:
            return "older_than_resume_token"
        }
    }

    private func isBeforeResumeCursor(modifiedAt: Date, path: String, cursor: ResumeCursor) -> Bool {
        let timestamp = modifiedAt.timeIntervalSince1970
        let epsilon: TimeInterval = 0.000_001
        if timestamp < cursor.timestamp - epsilon {
            return true
        }
        if timestamp > cursor.timestamp + epsilon {
            return false
        }
        guard let cursorPath = cursor.path else {
            return false
        }
        // Sorting is descending by path for equal timestamps.
        // Next page should only include lexicographically smaller paths.
        return path < cursorPath
    }

    private func decodeResumeCursor(_ token: String?) -> ResumeCursor? {
        guard let token, !token.isEmpty else {
            return nil
        }
        if let separator = token.firstIndex(of: "|") {
            let tsPart = String(token[..<separator])
            let pathPart = String(token[token.index(after: separator)...])
            let decodedPath = pathPart.removingPercentEncoding ?? pathPart
            if let timestamp = TimeInterval(tsPart) {
                return ResumeCursor(timestamp: timestamp, path: decodedPath)
            }
            if let date = ISO8601DateFormatter().date(from: tsPart) {
                return ResumeCursor(timestamp: date.timeIntervalSince1970, path: decodedPath)
            }
        }
        if let timestamp = TimeInterval(token) {
            return ResumeCursor(timestamp: timestamp, path: nil)
        }
        if let date = ISO8601DateFormatter().date(from: token) {
            return ResumeCursor(timestamp: date.timeIntervalSince1970, path: nil)
        }
        return nil
    }

    private func encodeResumeCursor(timestamp: TimeInterval, path: String) -> String {
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return "\(timestamp)|\(encodedPath)"
    }
}
