import Foundation
import HivecrewRetrievalProtocol

public actor RetrievalMetrics {
    private struct SourceAccumulator {
        var queueDepth = 0
        var inFlightCount = 0
        var cumulativeProcessedCount = 0
        var extractionSuccessCount = 0
        var extractionPartialCount = 0
        var extractionFailedCount = 0
        var extractionUnsupportedCount = 0
        var extractionOCRCount = 0
        var lastScanCandidatesSeen = 0
        var lastScanCandidatesSkippedExcluded = 0
        var lastScanEventsEmitted = 0
        var lastScanAt: Date?
        var currentOperation: RetrievalOperationPhase = .idle
        var currentItemPath: String?
        var updatedAt: Date = Date()
    }

    private var latencies: [Int] = []
    private var queueDepth: Int = 0
    private var inFlightCount: Int = 0
    private var lastError: String?
    private var resumeSuccessCount = 0
    private var resumeFailureCount = 0
    private var extractionSuccessCount = 0
    private var extractionPartialCount = 0
    private var extractionFailedCount = 0
    private var extractionUnsupportedCount = 0
    private var extractionOCRCount = 0
    private var sourceAccumulators: [RetrievalSourceType: SourceAccumulator] = [:]
    private var currentOperation: RetrievalOperationPhase = .idle
    private var currentOperationSourceType: RetrievalSourceType?
    private var currentItemPath: String?
    private var operationUpdatedAt: Date = Date()

    public init() {}

    public func recordLatency(_ latencyMs: Int) {
        latencies.append(latencyMs)
        if latencies.count > 1_000 {
            latencies.removeFirst(latencies.count - 1_000)
        }
    }

    public func setQueueState(totalDepth: Int, bySource: [RetrievalSourceType: Int]) {
        queueDepth = max(0, totalDepth)
        for source in RetrievalSourceType.allCases {
            var accumulator = sourceAccumulators[source, default: SourceAccumulator()]
            accumulator.queueDepth = max(0, bySource[source] ?? 0)
            accumulator.updatedAt = Date()
            sourceAccumulators[source] = accumulator
        }
        normalizeOperationIfIdle()
    }

    public func recordError(_ error: Error) {
        lastError = error.localizedDescription
    }

    public func recordResume(success: Bool) {
        if success {
            resumeSuccessCount += 1
        } else {
            resumeFailureCount += 1
        }
    }

    public func beginBackfill(sourceType: RetrievalSourceType? = nil, path: String? = nil) {
        setCurrentOperation(.backfilling, sourceType: sourceType, path: path)
    }

    public func endBackfill(sourceType: RetrievalSourceType? = nil) {
        if let sourceType {
            var accumulator = sourceAccumulators[sourceType, default: SourceAccumulator()]
            if accumulator.currentOperation == .backfilling {
                accumulator.currentOperation = .idle
                accumulator.currentItemPath = nil
                accumulator.updatedAt = Date()
                sourceAccumulators[sourceType] = accumulator
            }
        }
        normalizeOperationIfIdle()
    }

    public func beginIngestion(sourceType: RetrievalSourceType, path: String?) {
        inFlightCount += 1
        var accumulator = sourceAccumulators[sourceType, default: SourceAccumulator()]
        accumulator.inFlightCount += 1
        accumulator.currentOperation = .ingesting
        accumulator.currentItemPath = path
        accumulator.updatedAt = Date()
        sourceAccumulators[sourceType] = accumulator
        setCurrentOperation(.ingesting, sourceType: sourceType, path: path)
    }

    public func endIngestion(sourceType: RetrievalSourceType, path: String?, success: Bool) {
        _ = success
        inFlightCount = max(0, inFlightCount - 1)
        var accumulator = sourceAccumulators[sourceType, default: SourceAccumulator()]
        accumulator.inFlightCount = max(0, accumulator.inFlightCount - 1)
        if accumulator.inFlightCount == 0 {
            accumulator.currentOperation = .idle
            if accumulator.currentItemPath == path {
                accumulator.currentItemPath = nil
            }
        }
        accumulator.updatedAt = Date()
        sourceAccumulators[sourceType] = accumulator
        normalizeOperationIfIdle()
    }

    public func recordDocumentPersisted(sourceType: RetrievalSourceType, path: String?) {
        var accumulator = sourceAccumulators[sourceType, default: SourceAccumulator()]
        accumulator.cumulativeProcessedCount += 1
        accumulator.currentOperation = .ingesting
        accumulator.currentItemPath = path
        accumulator.updatedAt = Date()
        sourceAccumulators[sourceType] = accumulator
        setCurrentOperation(.ingesting, sourceType: sourceType, path: path)
    }

    public func recordExtraction(
        _ telemetry: ExtractionTelemetry,
        sourceType: RetrievalSourceType,
        path: String? = nil
    ) {
        switch telemetry.outcome {
        case .success:
            extractionSuccessCount += 1
        case .partial:
            extractionPartialCount += 1
        case .failed:
            extractionFailedCount += 1
        case .unsupported:
            extractionUnsupportedCount += 1
        }
        if telemetry.usedOCR {
            extractionOCRCount += 1
        }
        var accumulator = sourceAccumulators[sourceType, default: SourceAccumulator()]
        switch telemetry.outcome {
        case .success:
            accumulator.extractionSuccessCount += 1
        case .partial:
            accumulator.extractionPartialCount += 1
        case .failed:
            accumulator.extractionFailedCount += 1
        case .unsupported:
            accumulator.extractionUnsupportedCount += 1
        }
        if telemetry.usedOCR {
            accumulator.extractionOCRCount += 1
        }
        accumulator.currentOperation = .extracting
        accumulator.currentItemPath = path
        accumulator.updatedAt = Date()
        sourceAccumulators[sourceType] = accumulator
        setCurrentOperation(.extracting, sourceType: sourceType, path: path)
    }

    public func recordScanBatch(_ stats: FileConnector.ScanBatchStats, sourceType: RetrievalSourceType) {
        var accumulator = sourceAccumulators[sourceType, default: SourceAccumulator()]
        accumulator.lastScanCandidatesSeen = stats.candidatesSeen
        accumulator.lastScanCandidatesSkippedExcluded = stats.candidatesSkippedExcluded
        accumulator.lastScanEventsEmitted = stats.eventsEmitted
        accumulator.lastScanAt = stats.occurredAt
        accumulator.currentOperation = .scanning
        accumulator.updatedAt = Date()
        sourceAccumulators[sourceType] = accumulator
        setCurrentOperation(.scanning, sourceType: sourceType, path: nil)
    }

    public func health(version: String) -> RetrievalHealth {
        let sorted = latencies.sorted()
        let p50 = percentile(sorted, 0.5)
        let p95 = percentile(sorted, 0.95)
        return RetrievalHealth(
            daemonVersion: version,
            running: true,
            queueDepth: queueDepth,
            inFlightCount: inFlightCount,
            lastError: lastError,
            latencyP50Ms: p50,
            latencyP95Ms: p95,
            currentOperation: currentOperation,
            currentOperationSourceType: currentOperationSourceType,
            currentItemPath: currentItemPath,
            extractionSuccessCount: extractionSuccessCount,
            extractionPartialCount: extractionPartialCount,
            extractionFailedCount: extractionFailedCount,
            extractionUnsupportedCount: extractionUnsupportedCount,
            extractionOCRCount: extractionOCRCount
        )
    }

    public func sourceRuntimeStates() -> [RetrievalSourceRuntimeState] {
        RetrievalSourceType.allCases.map { sourceType in
            let accumulator = sourceAccumulators[sourceType, default: SourceAccumulator()]
            return RetrievalSourceRuntimeState(
                sourceType: sourceType,
                queueDepth: accumulator.queueDepth,
                inFlightCount: accumulator.inFlightCount,
                cumulativeProcessedCount: accumulator.cumulativeProcessedCount,
                extractionSuccessCount: accumulator.extractionSuccessCount,
                extractionPartialCount: accumulator.extractionPartialCount,
                extractionFailedCount: accumulator.extractionFailedCount,
                extractionUnsupportedCount: accumulator.extractionUnsupportedCount,
                extractionOCRCount: accumulator.extractionOCRCount,
                lastScanCandidatesSeen: accumulator.lastScanCandidatesSeen,
                lastScanCandidatesSkippedExcluded: accumulator.lastScanCandidatesSkippedExcluded,
                lastScanEventsEmitted: accumulator.lastScanEventsEmitted,
                lastScanAt: accumulator.lastScanAt,
                currentOperation: accumulator.currentOperation,
                currentItemPath: accumulator.currentItemPath,
                updatedAt: accumulator.updatedAt
            )
        }
    }

    public func operationContext() -> (phase: RetrievalOperationPhase, sourceType: RetrievalSourceType?, path: String?) {
        (currentOperation, currentOperationSourceType, currentItemPath)
    }

    private func percentile(_ values: [Int], _ percentile: Double) -> Int {
        guard !values.isEmpty else { return 0 }
        let index = Int(Double(values.count - 1) * percentile)
        return values[max(0, min(values.count - 1, index))]
    }

    private func normalizeOperationIfIdle() {
        if inFlightCount == 0 && queueDepth == 0 {
            setCurrentOperation(.idle, sourceType: nil, path: nil)
        } else if inFlightCount == 0 && queueDepth > 0 && currentOperation == .idle {
            setCurrentOperation(.backfilling, sourceType: .file, path: nil)
        }
    }

    private func setCurrentOperation(
        _ phase: RetrievalOperationPhase,
        sourceType: RetrievalSourceType?,
        path: String?
    ) {
        currentOperation = phase
        currentOperationSourceType = sourceType
        currentItemPath = path
        operationUpdatedAt = Date()
        if let sourceType {
            var accumulator = sourceAccumulators[sourceType, default: SourceAccumulator()]
            accumulator.currentOperation = phase
            accumulator.currentItemPath = path
            accumulator.updatedAt = Date()
            sourceAccumulators[sourceType] = accumulator
        }
    }
}
