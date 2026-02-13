import Foundation
import HivecrewRetrievalProtocol

public struct RetrievalDocument: Sendable, Codable {
    public let id: String
    public let sourceType: RetrievalSourceType
    public let sourceId: String
    public let title: String
    public let body: String
    public let sourcePathOrHandle: String
    public let updatedAt: Date
    public let risk: RetrievalRiskLabel
    public let partition: String
    public let searchable: Bool
}
