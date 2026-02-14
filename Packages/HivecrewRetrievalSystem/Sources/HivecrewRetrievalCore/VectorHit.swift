import Foundation
import HivecrewRetrievalProtocol

public struct VectorHit: Sendable {
    public let chunkId: String
    public let documentId: String
    public let chunkIndex: Int
    public let chunkText: String
    public let similarity: Double
    public let sourceType: RetrievalSourceType
    public let title: String
    public let sourcePathOrHandle: String
    public let risk: RetrievalRiskLabel
    public let updatedAt: Date
}
