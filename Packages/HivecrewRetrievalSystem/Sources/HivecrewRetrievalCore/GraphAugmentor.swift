import Foundation
import HivecrewRetrievalProtocol

public actor GraphAugmentor {
    private let store: RetrievalStore

    public init(store: RetrievalStore) {
        self.store = store
    }

    public func score(
        seedDocumentIds: Set<String>,
        typingMode: Bool
    ) async -> [String: Double] {
        let start = Date()
        let maxEdges = typingMode ? 80 : 400
        let budget: TimeInterval = typingMode ? 0.03 : 0.15

        guard let edges = try? await store.graphNeighbors(seedDocumentIds: seedDocumentIds, maxEdges: maxEdges) else {
            return [:]
        }

        var scores: [String: Double] = [:]
        for edge in edges {
            if Date().timeIntervalSince(start) > budget { break }
            let score = edge.confidence * edge.weight
            scores[edge.sourceNode, default: 0] += score
            scores[edge.targetNode, default: 0] += score
        }
        return scores
    }
}
