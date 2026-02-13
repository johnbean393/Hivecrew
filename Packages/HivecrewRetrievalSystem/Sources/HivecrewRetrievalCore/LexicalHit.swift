import Foundation
import HivecrewRetrievalProtocol

public struct LexicalHit: Sendable {
    public let documentId: String
    public let sourceType: RetrievalSourceType
    public let title: String
    public let sourcePathOrHandle: String
    public let risk: RetrievalRiskLabel
    public let updatedAt: Date
    public let snippet: String
}
