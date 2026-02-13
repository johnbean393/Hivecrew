import Foundation
import HivecrewRetrievalProtocol

public struct BackfillCheckpoint: Sendable, Codable {
    public let key: String
    public let sourceType: RetrievalSourceType
    public let scopeLabel: String
    public let cursor: String?
    public let lastIndexedPath: String?
    public let lastIndexedTimestamp: Date?
    public let resumeToken: String?
    public let itemsProcessed: Int
    public let itemsSkipped: Int
    public let estimatedTotal: Int
    public let status: String
    public let updatedAt: Date

    public init(
        key: String,
        sourceType: RetrievalSourceType,
        scopeLabel: String,
        cursor: String? = nil,
        lastIndexedPath: String? = nil,
        lastIndexedTimestamp: Date? = nil,
        resumeToken: String? = nil,
        itemsProcessed: Int,
        itemsSkipped: Int,
        estimatedTotal: Int,
        status: String,
        updatedAt: Date = Date()
    ) {
        self.key = key
        self.sourceType = sourceType
        self.scopeLabel = scopeLabel
        self.cursor = cursor
        self.lastIndexedPath = lastIndexedPath
        self.lastIndexedTimestamp = lastIndexedTimestamp
        self.resumeToken = resumeToken
        self.itemsProcessed = itemsProcessed
        self.itemsSkipped = itemsSkipped
        self.estimatedTotal = estimatedTotal
        self.status = status
        self.updatedAt = updatedAt
    }
}
