import Foundation
import HivecrewRetrievalProtocol

public actor LocalReranker {
    public init() {}

    public func rerank(
        query: String,
        suggestions: [RetrievalSuggestion],
        typingMode: Bool
    ) -> [RetrievalSuggestion] {
        let topK = typingMode ? 24 : 60
        let queryTokens = Set(tokenize(query))
        return suggestions
            .prefix(topK)
            .map { suggestion in
                let titleOverlap = overlap(tokens: queryTokens, text: suggestion.title)
                let snippetOverlap = overlap(tokens: queryTokens, text: suggestion.snippet)
                let recencyBoost = suggestion.timestamp.map { max(0, 1 - min(1, Date().timeIntervalSince($0) / 604_800)) } ?? 0
                let rerank = suggestion.relevanceScore + titleOverlap * 0.22 + snippetOverlap * 0.3 + recencyBoost * 0.12
                return RetrievalSuggestion(
                    id: suggestion.id,
                    sourceType: suggestion.sourceType,
                    title: suggestion.title,
                    snippet: suggestion.snippet,
                    sourceId: suggestion.sourceId,
                    sourcePathOrHandle: suggestion.sourcePathOrHandle,
                    relevanceScore: rerank,
                    graphScore: suggestion.graphScore,
                    risk: suggestion.risk,
                    reasons: suggestion.reasons + ["reranked-local"],
                    timestamp: suggestion.timestamp
                )
            }
            .sorted(by: { $0.relevanceScore > $1.relevanceScore })
    }

    private func tokenize(_ text: String) -> [String] {
        text
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    private func overlap(tokens: Set<String>, text: String) -> Double {
        guard !tokens.isEmpty else { return 0 }
        let words = Set(tokenize(text))
        let hit = tokens.intersection(words).count
        return Double(hit) / Double(tokens.count)
    }
}
