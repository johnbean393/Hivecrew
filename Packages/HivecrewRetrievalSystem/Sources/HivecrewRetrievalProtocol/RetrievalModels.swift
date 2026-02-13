import Foundation

public enum RetrievalSourceType: String, Codable, Sendable, CaseIterable {
    case file
    case email
    case message
    case calendar
}

public enum RetrievalInjectionMode: String, Codable, Sendable, CaseIterable {
    case fileRef
    case inlineSnippet
    case structuredSummary

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "fileRef", "file_ref":
            self = .fileRef
        case "inlineSnippet", "inline_snippet":
            self = .inlineSnippet
        case "structuredSummary", "structured_summary":
            self = .structuredSummary
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown RetrievalInjectionMode value: \(raw)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum RetrievalRiskLabel: String, Codable, Sendable, CaseIterable {
    case low
    case medium
    case high
}

public enum RetrievalOperationPhase: String, Codable, Sendable, CaseIterable {
    case idle
    case scanning
    case extracting
    case ingesting
    case backfilling
}

public struct RetrievalSuggestion: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let sourceType: RetrievalSourceType
    public let title: String
    public let snippet: String
    public let sourceId: String
    public let sourcePathOrHandle: String
    public let relevanceScore: Double
    public let graphScore: Double
    public let risk: RetrievalRiskLabel
    public let reasons: [String]
    public let timestamp: Date?

    public init(
        id: String = UUID().uuidString,
        sourceType: RetrievalSourceType,
        title: String,
        snippet: String,
        sourceId: String,
        sourcePathOrHandle: String,
        relevanceScore: Double,
        graphScore: Double = 0,
        risk: RetrievalRiskLabel = .low,
        reasons: [String] = [],
        timestamp: Date? = nil
    ) {
        self.id = id
        self.sourceType = sourceType
        self.title = title
        self.snippet = snippet
        self.sourceId = sourceId
        self.sourcePathOrHandle = sourcePathOrHandle
        self.relevanceScore = relevanceScore
        self.graphScore = graphScore
        self.risk = risk
        self.reasons = reasons
        self.timestamp = timestamp
    }
}

public struct RetrievalSuggestRequest: Codable, Sendable {
    public let query: String
    public let sourceFilters: [RetrievalSourceType]?
    public let limit: Int
    public let typingMode: Bool
    public let includeColdPartitionFallback: Bool

    public init(
        query: String,
        sourceFilters: [RetrievalSourceType]? = nil,
        limit: Int = 12,
        typingMode: Bool = true,
        includeColdPartitionFallback: Bool = false
    ) {
        self.query = query
        self.sourceFilters = sourceFilters
        self.limit = limit
        self.typingMode = typingMode
        self.includeColdPartitionFallback = includeColdPartitionFallback
    }
}

public struct RetrievalSuggestResponse: Codable, Sendable {
    public let suggestions: [RetrievalSuggestion]
    public let partial: Bool
    public let totalCandidateCount: Int
    public let latencyMs: Int

    public init(
        suggestions: [RetrievalSuggestion],
        partial: Bool,
        totalCandidateCount: Int,
        latencyMs: Int
    ) {
        self.suggestions = suggestions
        self.partial = partial
        self.totalCandidateCount = totalCandidateCount
        self.latencyMs = latencyMs
    }
}

public struct RetrievalContextPackItem: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let sourceType: RetrievalSourceType
    public let mode: RetrievalInjectionMode
    public let title: String
    public let text: String
    public let filePath: String?
    public let metadata: [String: String]

    public init(
        id: String = UUID().uuidString,
        sourceType: RetrievalSourceType,
        mode: RetrievalInjectionMode,
        title: String,
        text: String,
        filePath: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.sourceType = sourceType
        self.mode = mode
        self.title = title
        self.text = text
        self.filePath = filePath
        self.metadata = metadata
    }
}

public struct RetrievalContextPack: Codable, Sendable, Equatable {
    public let id: String
    public let createdAt: Date
    public let query: String
    public let items: [RetrievalContextPackItem]
    public let attachmentPaths: [String]
    public let inlinePromptBlocks: [String]

    public init(
        id: String = UUID().uuidString,
        createdAt: Date = Date(),
        query: String,
        items: [RetrievalContextPackItem],
        attachmentPaths: [String],
        inlinePromptBlocks: [String]
    ) {
        self.id = id
        self.createdAt = createdAt
        self.query = query
        self.items = items
        self.attachmentPaths = attachmentPaths
        self.inlinePromptBlocks = inlinePromptBlocks
    }
}

public struct RetrievalCreateContextPackRequest: Codable, Sendable {
    public let query: String
    public let selectedSuggestionIds: [String]
    public let modeOverrides: [String: RetrievalInjectionMode]

    public init(
        query: String,
        selectedSuggestionIds: [String],
        modeOverrides: [String: RetrievalInjectionMode] = [:]
    ) {
        self.query = query
        self.selectedSuggestionIds = selectedSuggestionIds
        self.modeOverrides = modeOverrides
    }
}

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

