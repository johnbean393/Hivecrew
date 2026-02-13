import Foundation
import HivecrewRetrievalProtocol

public struct RetrievalChunk: Sendable, Codable {
    public let id: String
    public let documentId: String
    public let text: String
    public let index: Int
    public let embedding: [Float]
}
