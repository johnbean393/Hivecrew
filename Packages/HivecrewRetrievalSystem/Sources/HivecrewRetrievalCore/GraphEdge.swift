import Foundation
import HivecrewRetrievalProtocol

public struct GraphEdge: Sendable, Codable {
    public let id: String
    public let sourceNode: String
    public let targetNode: String
    public let edgeType: String
    public let confidence: Double
    public let weight: Double
    public let sourceType: RetrievalSourceType
    public let eventTime: Date?
    public let updatedAt: Date
}
