import Foundation
import HivecrewRetrievalProtocol

public actor HybridSearchEngine {
    private let store: RetrievalStore
    private let embeddingRuntime: EmbeddingRuntime
    private let graphAugmentor: GraphAugmentor
    private let reranker: LocalReranker

    public init(
        store: RetrievalStore,
        embeddingRuntime: EmbeddingRuntime,
        graphAugmentor: GraphAugmentor,
        reranker: LocalReranker
    ) {
        self.store = store
        self.embeddingRuntime = embeddingRuntime
        self.graphAugmentor = graphAugmentor
        self.reranker = reranker
    }

    public func suggest(request: RetrievalSuggestRequest) async throws -> RetrievalSuggestResponse {
        let start = Date()
        let sourceFilters = Set(request.sourceFilters ?? [.file])
        let partitionFilter: Set<String> = request.typingMode ? ["hot", "warm"] : ["hot", "warm", "cold"]
        let lexical = try await store.lexicalSearch(
            queryText: request.query,
            sourceFilters: sourceFilters,
            partitionFilter: partitionFilter,
            limit: request.typingMode ? 64 : 128
        )
        let (queryEmbeddings, _) = try await embeddingRuntime.embed(texts: [request.query])
        let queryVector = queryEmbeddings.first ?? []

        var vectors = try await store.allChunkVectors(
            sourceFilters: sourceFilters,
            partitionFilter: partitionFilter,
            limit: request.typingMode ? 600 : 1_600
        )
        if request.includeColdPartitionFallback && vectors.count < 120 {
            vectors = try await store.allChunkVectors(
                sourceFilters: sourceFilters,
                partitionFilter: ["hot", "warm", "cold"],
                limit: request.typingMode ? 800 : 2_400
            )
        }

        var merged: [String: RetrievalSuggestion] = [:]
        for (rank, hit) in lexical.enumerated() {
            let lexicalScore = 1.0 / Double(rank + 1)
            let recency = CandidateScorer.recencyWeight(date: hit.updatedAt)
            let score = lexicalScore * 0.6 + recency * 0.25
            merged[hit.documentId] = RetrievalSuggestion(
                id: hit.documentId,
                sourceType: hit.sourceType,
                title: hit.title,
                snippet: String(hit.snippet.prefix(420)),
                sourceId: hit.documentId,
                sourcePathOrHandle: hit.sourcePathOrHandle,
                relevanceScore: score,
                risk: hit.risk,
                reasons: ["lexical", "recency"],
                timestamp: hit.updatedAt
            )
        }

        for hit in vectors {
            let similarity = CandidateScorer.cosineSimilarity(queryVector, hit.vector)
            guard similarity > 0 else { continue }
            let recency = CandidateScorer.recencyWeight(date: hit.updatedAt)
            let vectorScore = similarity * 0.65 + recency * 0.2
            if let existing = merged[hit.documentId] {
                let mergedScore = max(existing.relevanceScore, vectorScore) + min(existing.relevanceScore, vectorScore) * 0.2
                merged[hit.documentId] = RetrievalSuggestion(
                    id: existing.id,
                    sourceType: existing.sourceType,
                    title: existing.title,
                    snippet: existing.snippet,
                    sourceId: existing.sourceId,
                    sourcePathOrHandle: existing.sourcePathOrHandle,
                    relevanceScore: mergedScore,
                    graphScore: existing.graphScore,
                    risk: existing.risk,
                    reasons: Array(Set(existing.reasons + ["vector"])),
                    timestamp: existing.timestamp
                )
            } else {
                merged[hit.documentId] = RetrievalSuggestion(
                    id: hit.documentId,
                    sourceType: hit.sourceType,
                    title: hit.title,
                    snippet: hit.title,
                    sourceId: hit.documentId,
                    sourcePathOrHandle: hit.sourcePathOrHandle,
                    relevanceScore: vectorScore,
                    risk: hit.risk,
                    reasons: ["vector"],
                    timestamp: hit.updatedAt
                )
            }
        }

        let seed = Set(merged.keys.prefix(request.typingMode ? 12 : 36))
        let graphScores = await graphAugmentor.score(seedDocumentIds: seed, typingMode: request.typingMode)
        for (id, graphScore) in graphScores {
            guard var suggestion = merged[id] else { continue }
            suggestion = RetrievalSuggestion(
                id: suggestion.id,
                sourceType: suggestion.sourceType,
                title: suggestion.title,
                snippet: suggestion.snippet,
                sourceId: suggestion.sourceId,
                sourcePathOrHandle: suggestion.sourcePathOrHandle,
                relevanceScore: suggestion.relevanceScore + (graphScore * 0.16),
                graphScore: graphScore,
                risk: suggestion.risk,
                reasons: Array(Set(suggestion.reasons + ["graph"])),
                timestamp: suggestion.timestamp
            )
            merged[id] = suggestion
        }

        let sorted = merged.values.sorted(by: { $0.relevanceScore > $1.relevanceScore })
        let reranked = await reranker.rerank(query: request.query, suggestions: sorted, typingMode: request.typingMode)
        let finalSuggestions = Array(reranked.prefix(max(1, request.limit)))
        return RetrievalSuggestResponse(
            suggestions: finalSuggestions,
            partial: request.typingMode,
            totalCandidateCount: merged.count,
            latencyMs: Int(Date().timeIntervalSince(start) * 1_000)
        )
    }
}
