import Foundation

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
