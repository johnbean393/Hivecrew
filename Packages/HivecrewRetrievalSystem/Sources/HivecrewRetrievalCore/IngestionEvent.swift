import Foundation
import HivecrewRetrievalProtocol

public enum IngestionOperation: String, Sendable, Codable, Hashable {
    case upsert
    case delete
}

public struct IngestionEvent: Sendable, Codable, Hashable {
    public let id: String
    public let operation: IngestionOperation
    public let sourceType: RetrievalSourceType
    public let scopeLabel: String
    public let sourceId: String
    public let title: String
    public let body: String
    public let sourcePathOrHandle: String
    public let occurredAt: Date

    public init(
        id: String = UUID().uuidString,
        operation: IngestionOperation = .upsert,
        sourceType: RetrievalSourceType,
        scopeLabel: String,
        sourceId: String,
        title: String,
        body: String,
        sourcePathOrHandle: String,
        occurredAt: Date = Date()
    ) {
        self.id = id
        self.operation = operation
        self.sourceType = sourceType
        self.scopeLabel = scopeLabel
        self.sourceId = sourceId
        self.title = title
        self.body = body
        self.sourcePathOrHandle = sourcePathOrHandle
        self.occurredAt = occurredAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case operation
        case sourceType
        case scopeLabel
        case sourceId
        case title
        case body
        case sourcePathOrHandle
        case occurredAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        operation = try container.decodeIfPresent(IngestionOperation.self, forKey: .operation) ?? .upsert
        sourceType = try container.decode(RetrievalSourceType.self, forKey: .sourceType)
        scopeLabel = try container.decode(String.self, forKey: .scopeLabel)
        sourceId = try container.decode(String.self, forKey: .sourceId)
        title = try container.decode(String.self, forKey: .title)
        body = try container.decode(String.self, forKey: .body)
        sourcePathOrHandle = try container.decode(String.self, forKey: .sourcePathOrHandle)
        occurredAt = try container.decode(Date.self, forKey: .occurredAt)
    }
}
