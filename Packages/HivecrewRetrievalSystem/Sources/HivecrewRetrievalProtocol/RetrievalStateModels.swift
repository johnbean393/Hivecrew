import Foundation

public struct RetrievalProgressState: Codable, Sendable, Equatable {
    public let sourceType: RetrievalSourceType
    public let scopeLabel: String
    public let status: String
    public let itemsProcessed: Int
    public let itemsSkipped: Int
    public let estimatedTotal: Int
    public let percentComplete: Double
    public let etaSeconds: Int?
    public let checkpointUpdatedAt: Date

    public init(
        sourceType: RetrievalSourceType,
        scopeLabel: String,
        status: String,
        itemsProcessed: Int,
        itemsSkipped: Int,
        estimatedTotal: Int,
        percentComplete: Double,
        etaSeconds: Int?,
        checkpointUpdatedAt: Date
    ) {
        self.sourceType = sourceType
        self.scopeLabel = scopeLabel
        self.status = status
        self.itemsProcessed = itemsProcessed
        self.itemsSkipped = itemsSkipped
        self.estimatedTotal = estimatedTotal
        self.percentComplete = percentComplete
        self.etaSeconds = etaSeconds
        self.checkpointUpdatedAt = checkpointUpdatedAt
    }
}

public struct RetrievalIndexedSourceStats: Codable, Sendable, Equatable, Identifiable {
    public let sourceType: RetrievalSourceType
    public let documentCount: Int
    public let lastDocumentUpdatedAt: Date?

    public var id: RetrievalSourceType { sourceType }

    public init(
        sourceType: RetrievalSourceType,
        documentCount: Int,
        lastDocumentUpdatedAt: Date?
    ) {
        self.sourceType = sourceType
        self.documentCount = documentCount
        self.lastDocumentUpdatedAt = lastDocumentUpdatedAt
    }
}

public struct RetrievalIndexStats: Codable, Sendable, Equatable {
    public let totalDocumentCount: Int
    public let sources: [RetrievalIndexedSourceStats]

    public init(
        totalDocumentCount: Int,
        sources: [RetrievalIndexedSourceStats]
    ) {
        self.totalDocumentCount = totalDocumentCount
        self.sources = sources
    }
}

public struct RetrievalQueueSourceActivity: Codable, Sendable, Equatable, Identifiable {
    public let sourceType: RetrievalSourceType
    public let queuedItemCount: Int

    public var id: RetrievalSourceType { sourceType }

    public init(
        sourceType: RetrievalSourceType,
        queuedItemCount: Int
    ) {
        self.sourceType = sourceType
        self.queuedItemCount = queuedItemCount
    }
}

public struct RetrievalQueueActivity: Codable, Sendable, Equatable {
    public let queueDepth: Int
    public let sources: [RetrievalQueueSourceActivity]

    public init(
        queueDepth: Int,
        sources: [RetrievalQueueSourceActivity]
    ) {
        self.queueDepth = queueDepth
        self.sources = sources
    }
}

public struct RetrievalHealth: Codable, Sendable, Equatable {
    public let daemonVersion: String
    public let running: Bool
    public let queueDepth: Int
    public let inFlightCount: Int
    public let lastError: String?
    public let latencyP50Ms: Int
    public let latencyP95Ms: Int
    public let currentOperation: RetrievalOperationPhase
    public let currentOperationSourceType: RetrievalSourceType?
    public let currentItemPath: String?
    public let extractionSuccessCount: Int
    public let extractionPartialCount: Int
    public let extractionFailedCount: Int
    public let extractionUnsupportedCount: Int
    public let extractionOCRCount: Int

    public init(
        daemonVersion: String,
        running: Bool,
        queueDepth: Int,
        inFlightCount: Int = 0,
        lastError: String?,
        latencyP50Ms: Int,
        latencyP95Ms: Int,
        currentOperation: RetrievalOperationPhase = .idle,
        currentOperationSourceType: RetrievalSourceType? = nil,
        currentItemPath: String? = nil,
        extractionSuccessCount: Int = 0,
        extractionPartialCount: Int = 0,
        extractionFailedCount: Int = 0,
        extractionUnsupportedCount: Int = 0,
        extractionOCRCount: Int = 0
    ) {
        self.daemonVersion = daemonVersion
        self.running = running
        self.queueDepth = queueDepth
        self.inFlightCount = inFlightCount
        self.lastError = lastError
        self.latencyP50Ms = latencyP50Ms
        self.latencyP95Ms = latencyP95Ms
        self.currentOperation = currentOperation
        self.currentOperationSourceType = currentOperationSourceType
        self.currentItemPath = currentItemPath
        self.extractionSuccessCount = extractionSuccessCount
        self.extractionPartialCount = extractionPartialCount
        self.extractionFailedCount = extractionFailedCount
        self.extractionUnsupportedCount = extractionUnsupportedCount
        self.extractionOCRCount = extractionOCRCount
    }
}

public struct RetrievalSourceRuntimeState: Codable, Sendable, Equatable, Identifiable {
    public let sourceType: RetrievalSourceType
    public let queueDepth: Int
    public let inFlightCount: Int
    public let cumulativeProcessedCount: Int
    public let extractionSuccessCount: Int
    public let extractionPartialCount: Int
    public let extractionFailedCount: Int
    public let extractionUnsupportedCount: Int
    public let extractionOCRCount: Int
    public let lastScanCandidatesSeen: Int
    public let lastScanCandidatesSkippedExcluded: Int
    public let lastScanEventsEmitted: Int
    public let lastScanAt: Date?
    public let currentOperation: RetrievalOperationPhase
    public let currentItemPath: String?
    public let updatedAt: Date

    public var id: RetrievalSourceType { sourceType }

    public init(
        sourceType: RetrievalSourceType,
        queueDepth: Int = 0,
        inFlightCount: Int = 0,
        cumulativeProcessedCount: Int = 0,
        extractionSuccessCount: Int = 0,
        extractionPartialCount: Int = 0,
        extractionFailedCount: Int = 0,
        extractionUnsupportedCount: Int = 0,
        extractionOCRCount: Int = 0,
        lastScanCandidatesSeen: Int = 0,
        lastScanCandidatesSkippedExcluded: Int = 0,
        lastScanEventsEmitted: Int = 0,
        lastScanAt: Date? = nil,
        currentOperation: RetrievalOperationPhase = .idle,
        currentItemPath: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.sourceType = sourceType
        self.queueDepth = queueDepth
        self.inFlightCount = inFlightCount
        self.cumulativeProcessedCount = cumulativeProcessedCount
        self.extractionSuccessCount = extractionSuccessCount
        self.extractionPartialCount = extractionPartialCount
        self.extractionFailedCount = extractionFailedCount
        self.extractionUnsupportedCount = extractionUnsupportedCount
        self.extractionOCRCount = extractionOCRCount
        self.lastScanCandidatesSeen = lastScanCandidatesSeen
        self.lastScanCandidatesSkippedExcluded = lastScanCandidatesSkippedExcluded
        self.lastScanEventsEmitted = lastScanEventsEmitted
        self.lastScanAt = lastScanAt
        self.currentOperation = currentOperation
        self.currentItemPath = currentItemPath
        self.updatedAt = updatedAt
    }
}

public struct RetrievalStateSnapshot: Codable, Sendable, Equatable {
    public let health: RetrievalHealth
    public let progress: [RetrievalProgressState]
    public let indexStats: RetrievalIndexStats
    public let queueActivity: RetrievalQueueActivity
    public let sourceRuntime: [RetrievalSourceRuntimeState]
    public let currentOperation: RetrievalOperationPhase
    public let currentOperationSourceType: RetrievalSourceType?
    public let currentItemPath: String?
    public let updatedAt: Date

    public init(
        health: RetrievalHealth,
        progress: [RetrievalProgressState],
        indexStats: RetrievalIndexStats,
        queueActivity: RetrievalQueueActivity,
        sourceRuntime: [RetrievalSourceRuntimeState],
        currentOperation: RetrievalOperationPhase,
        currentOperationSourceType: RetrievalSourceType? = nil,
        currentItemPath: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.health = health
        self.progress = progress
        self.indexStats = indexStats
        self.queueActivity = queueActivity
        self.sourceRuntime = sourceRuntime
        self.currentOperation = currentOperation
        self.currentOperationSourceType = currentOperationSourceType
        self.currentItemPath = currentItemPath
        self.updatedAt = updatedAt
    }
}

public struct RetrievalSourceScope: Codable, Sendable, Equatable {
    public let sourceType: RetrievalSourceType
    public let includePathsOrHandles: [String]
    public let excludePathsOrHandles: [String]
    public let enabled: Bool

    public init(
        sourceType: RetrievalSourceType,
        includePathsOrHandles: [String] = [],
        excludePathsOrHandles: [String] = [],
        enabled: Bool = true
    ) {
        self.sourceType = sourceType
        self.includePathsOrHandles = includePathsOrHandles
        self.excludePathsOrHandles = excludePathsOrHandles
        self.enabled = enabled
    }
}

public struct RetrievalConfigureScopesRequest: Codable, Sendable {
    public let scopes: [RetrievalSourceScope]

    public init(scopes: [RetrievalSourceScope]) {
        self.scopes = scopes
    }
}

public struct RetrievalBackfillJob: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let sourceType: RetrievalSourceType
    public let scopeLabel: String
    public let status: String
    public let resumeToken: String?
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        sourceType: RetrievalSourceType,
        scopeLabel: String,
        status: String,
        resumeToken: String?,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.sourceType = sourceType
        self.scopeLabel = scopeLabel
        self.status = status
        self.resumeToken = resumeToken
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum RetrievalAPIPath {
    public static let health = "/health"
    public static let suggest = "/api/v1/retrieval/suggest"
    public static let createContextPack = "/api/v1/retrieval/context-pack"
    public static let preview = "/api/v1/retrieval/preview"
    public static let state = "/api/v1/retrieval/state"
    public static let progress = "/api/v1/retrieval/progress"
    public static let indexStats = "/api/v1/retrieval/index-stats"
    public static let activity = "/api/v1/retrieval/activity"
    public static let backfillJobs = "/api/v1/retrieval/backfill/jobs"
    public static let pauseBackfill = "/api/v1/retrieval/backfill/pause"
    public static let resumeBackfill = "/api/v1/retrieval/backfill/resume"
    public static let configureScopes = "/api/v1/retrieval/scopes"
    public static let triggerBackfill = "/api/v1/retrieval/backfill/trigger"
}

public enum RetrievalAPIHeader {
    public static let authToken = "X-Retrieval-Token"
}
