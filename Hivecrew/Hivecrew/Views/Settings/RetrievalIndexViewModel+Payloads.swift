import Foundation

struct RetrievalStatePayload: Decodable {
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

struct RetrievalHealthPayloadV2: Decodable {
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

struct RetrievalProgressPayload: Decodable {
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

struct RetrievalSourceStatsPayload: Decodable {
    let sourceType: String
    let documentCount: Int
    let lastDocumentUpdatedAt: Date?
}

struct RetrievalIndexStatsPayloadV2: Decodable {
    let totalDocumentCount: Int
    let sources: [RetrievalSourceStatsPayload]
}

struct RetrievalQueueSourcePayload: Decodable {
    let sourceType: String
    let queuedItemCount: Int
}

struct RetrievalQueueActivityPayloadV2: Decodable {
    let queueDepth: Int
    let sources: [RetrievalQueueSourcePayload]
}

struct RetrievalSourceRuntimePayload: Decodable {
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

enum RetrievalOperationPayload: String {
    case idle
    case scanning
    case extracting
    case ingesting
    case backfilling
}
