import Foundation
import HivecrewRetrievalProtocol

public struct IngestionEvent: Sendable, Codable, Hashable {
    public let id: String
    public let sourceType: RetrievalSourceType
    public let scopeLabel: String
    public let sourceId: String
    public let title: String
    public let body: String
    public let sourcePathOrHandle: String
    public let occurredAt: Date

    public init(
        id: String = UUID().uuidString,
        sourceType: RetrievalSourceType,
        scopeLabel: String,
        sourceId: String,
        title: String,
        body: String,
        sourcePathOrHandle: String,
        occurredAt: Date = Date()
    ) {
        self.id = id
        self.sourceType = sourceType
        self.scopeLabel = scopeLabel
        self.sourceId = sourceId
        self.title = title
        self.body = body
        self.sourcePathOrHandle = sourcePathOrHandle
        self.occurredAt = occurredAt
    }
}
