import Foundation
import HivecrewRetrievalProtocol

public actor HybridSearchEngine {
    private enum ScoreTuning {
        static let typingVectorTopK = 180
        static let deepVectorTopK = 360
        static let typingVectorScanLimit = 480
        static let deepVectorScanLimit = 960
        static let typingVectorFallbackTopK = 220
        static let deepVectorFallbackTopK = 420
        static let typingVectorFallbackScanLimit = 640
        static let deepVectorFallbackScanLimit = 1_200
        static let coldFallbackMinResultCount = 36
        static let typingVectorMinSimilarity: Double = 0.20
        static let deepVectorMinSimilarity: Double = 0.14
        static let typingGraphBoostCap: Double = 0.06
        static let deepGraphBoostCap: Double = 0.10
        static let graphBoostMaxRelativeToBase: Double = 0.22
        static let typingGraphEligibleMinBaseScore: Double = 0.32
        static let deepGraphEligibleMinBaseScore: Double = 0.26
    }
    private enum QueryTuning {
        static let compactQueryMinimumLength = 180
        static let compactQueryMaximumLength = 260
        static let compactQueryMaxKeywordTerms = 14
        static let stopWords: Set<String> = [
            "a", "an", "and", "are", "as", "at", "be", "but", "by", "do", "for", "from",
            "how", "i", "if", "in", "into", "is", "it", "me", "my", "of", "on", "or",
            "our", "please", "so", "that", "the", "their", "them", "there", "these",
            "this", "to", "us", "we", "with", "you", "your",
        ]
    }

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
        let retrievalQuery = Self.compactRetrievalQuery(request.query)
        let vectorSimilarityFloor = request.typingMode
            ? ScoreTuning.typingVectorMinSimilarity
            : ScoreTuning.deepVectorMinSimilarity
        let graphEligibleScoreFloor = request.typingMode
            ? ScoreTuning.typingGraphEligibleMinBaseScore
            : ScoreTuning.deepGraphEligibleMinBaseScore
        let graphAbsoluteBoostCap = request.typingMode
            ? ScoreTuning.typingGraphBoostCap
            : ScoreTuning.deepGraphBoostCap
        let sourceFilters = Set(request.sourceFilters ?? [.file])
        let partitionFilter: Set<String> = request.typingMode ? ["hot", "warm"] : ["hot", "warm", "cold"]
        let lexical = try await store.lexicalSearch(
            queryText: retrievalQuery,
            sourceFilters: sourceFilters,
            partitionFilter: partitionFilter,
            limit: request.typingMode ? 64 : 128
        )
        let (queryEmbeddings, _) = try await embeddingRuntime.embed(texts: [retrievalQuery])
        let queryVector = queryEmbeddings.first ?? []
        let vectorTopK = request.typingMode ? ScoreTuning.typingVectorTopK : ScoreTuning.deepVectorTopK
        let vectorScanLimit = request.typingMode ? ScoreTuning.typingVectorScanLimit : ScoreTuning.deepVectorScanLimit
        let fallbackVectorTopK = request.typingMode ? ScoreTuning.typingVectorFallbackTopK : ScoreTuning.deepVectorFallbackTopK
        let fallbackVectorScanLimit = request.typingMode
            ? ScoreTuning.typingVectorFallbackScanLimit
            : ScoreTuning.deepVectorFallbackScanLimit

        var vectors = try await store.topChunkVectorsBySimilarity(
            queryVector: queryVector,
            sourceFilters: sourceFilters,
            partitionFilter: partitionFilter,
            topK: vectorTopK,
            scanLimit: vectorScanLimit,
            minimumSimilarity: vectorSimilarityFloor
        )
        if request.includeColdPartitionFallback && vectors.count < ScoreTuning.coldFallbackMinResultCount {
            vectors = try await store.topChunkVectorsBySimilarity(
                queryVector: queryVector,
                sourceFilters: sourceFilters,
                partitionFilter: ["hot", "warm", "cold"],
                topK: fallbackVectorTopK,
                scanLimit: fallbackVectorScanLimit,
                minimumSimilarity: vectorSimilarityFloor
            )
        }

        var merged: [String: RetrievalSuggestion] = [:]
        for (rank, hit) in lexical.enumerated() {
            let lexicalScore = 1.0 / Double(rank + 1)
            let recency = CandidateScorer.recencyWeight(date: hit.updatedAt)
            let score = lexicalScore * 0.72 + recency * 0.12
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

        var vectorCandidatesSeen = 0
        var vectorCandidatesAccepted = 0
        for hit in vectors {
            vectorCandidatesSeen += 1
            let similarity = hit.similarity
            vectorCandidatesAccepted += 1
            let recency = CandidateScorer.recencyWeight(date: hit.updatedAt)
            let vectorScore = similarity * 0.62 + recency * 0.06
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
                let bestSnippet = hit.chunkText.trimmingCharacters(in: .whitespacesAndNewlines)
                merged[hit.documentId] = RetrievalSuggestion(
                    id: hit.documentId,
                    sourceType: hit.sourceType,
                    title: hit.title,
                    snippet: bestSnippet.isEmpty ? hit.title : String(bestSnippet.prefix(420)),
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
        var graphBoostApplied = 0
        var graphBoostSkipped = 0
        for (id, graphScore) in graphScores {
            guard var suggestion = merged[id] else { continue }
            let hasLexicalEvidence = suggestion.reasons.contains("lexical")
            let hasVectorEvidence = suggestion.reasons.contains("vector")
            let graphEligible = hasLexicalEvidence || (hasVectorEvidence && suggestion.relevanceScore >= graphEligibleScoreFloor)
            guard graphEligible else {
                graphBoostSkipped += 1
                continue
            }
            let rawGraphBoost = graphScore * 0.16
            let relativeGraphBoostCap = suggestion.relevanceScore * ScoreTuning.graphBoostMaxRelativeToBase
            let graphBoost = min(rawGraphBoost, graphAbsoluteBoostCap, max(0, relativeGraphBoostCap))
            guard graphBoost > 0 else {
                graphBoostSkipped += 1
                continue
            }
            suggestion = RetrievalSuggestion(
                id: suggestion.id,
                sourceType: suggestion.sourceType,
                title: suggestion.title,
                snippet: suggestion.snippet,
                sourceId: suggestion.sourceId,
                sourcePathOrHandle: suggestion.sourcePathOrHandle,
                relevanceScore: suggestion.relevanceScore + graphBoost,
                graphScore: graphScore,
                risk: suggestion.risk,
                reasons: Array(Set(suggestion.reasons + ["graph"])),
                timestamp: suggestion.timestamp
            )
            merged[id] = suggestion
            graphBoostApplied += 1
        }

        let sorted = merged.values.sorted(by: { $0.relevanceScore > $1.relevanceScore })
        let reranked = await reranker.rerank(query: request.query, suggestions: sorted, typingMode: request.typingMode)
        let finalSuggestions = Array(reranked.prefix(max(1, request.limit)))
        print(
            "HybridSearchEngine: suggest stats " +
                "[lexical=\(lexical.count), vectorSeen=\(vectorCandidatesSeen), " +
                "vectorAccepted=\(vectorCandidatesAccepted), merged=\(merged.count), " +
                "graphApplied=\(graphBoostApplied), graphSkipped=\(graphBoostSkipped), " +
                "queryChars=\(request.query.count), retrievalQueryChars=\(retrievalQuery.count)]"
        )
        return RetrievalSuggestResponse(
            suggestions: finalSuggestions,
            partial: request.typingMode,
            totalCandidateCount: merged.count,
            latencyMs: Int(Date().timeIntervalSince(start) * 1_000)
        )
    }

    private nonisolated static func compactRetrievalQuery(_ text: String) -> String {
        let cleaned = text
            .replacingOccurrences(of: "[^\\p{L}\\p{N}\\s_-]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return text }
        guard cleaned.count >= QueryTuning.compactQueryMinimumLength else { return cleaned }

        let keywords = cleaned
            .lowercased()
            .split(separator: " ")
            .map(String.init)
            .filter { token in
                token.count >= 3 && !QueryTuning.stopWords.contains(token)
            }
        let compactKeywords = uniqueOrdered(keywords).prefix(QueryTuning.compactQueryMaxKeywordTerms).joined(separator: " ")
        if compactKeywords.count >= 24 {
            return compactKeywords
        }
        return String(cleaned.prefix(QueryTuning.compactQueryMaximumLength))
    }

    private nonisolated static func uniqueOrdered(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for value in values {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty else { continue }
            guard !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            output.append(normalized)
        }
        return output
    }
}
