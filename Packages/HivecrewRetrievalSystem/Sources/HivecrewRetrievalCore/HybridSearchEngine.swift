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
    private enum DirectorySuggestionTuning {
        static let typingSeedSuggestions = 120
        static let deepSeedSuggestions = 320
        static let typingMaxSuggestions = 2
        static let deepMaxSuggestions = 4
        static let typingMinimumScore: Double = 0.58
        static let deepMinimumScore: Double = 0.5
        static let queryIntentTerms: Set<String> = [
            "directory", "folder", "template", "templates", "docs", "documentation",
            "repo", "repository", "project", "projects", "dataset", "datasets",
        ]
        static let cueSegments: Set<String> = [
            "docs", "documentation", "template", "templates",
            "examples", "samples", "resources",
        ]
        static let imageExtensions: Set<String> = [
            "png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff", "heic",
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
        let directorySuggestions = Self.directorySuggestions(
            query: request.query,
            suggestions: reranked,
            typingMode: request.typingMode
        )
        let mergedWithDirectories = Self.mergeSuggestions(
            base: reranked,
            additional: directorySuggestions
        )
        let finalSuggestions = Array(mergedWithDirectories.prefix(max(1, request.limit)))
        print(
            "HybridSearchEngine: suggest stats " +
                "[lexical=\(lexical.count), vectorSeen=\(vectorCandidatesSeen), " +
                "vectorAccepted=\(vectorCandidatesAccepted), merged=\(merged.count), " +
                "graphApplied=\(graphBoostApplied), graphSkipped=\(graphBoostSkipped), " +
                "directories=\(directorySuggestions.count), " +
                "queryChars=\(request.query.count), retrievalQueryChars=\(retrievalQuery.count)]"
        )
        return RetrievalSuggestResponse(
            suggestions: finalSuggestions,
            partial: request.typingMode,
            totalCandidateCount: max(merged.count, mergedWithDirectories.count),
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

    private nonisolated static func mergeSuggestions(
        base: [RetrievalSuggestion],
        additional: [RetrievalSuggestion]
    ) -> [RetrievalSuggestion] {
        var byID: [String: RetrievalSuggestion] = [:]
        for suggestion in base {
            byID[suggestion.id] = suggestion
        }
        for suggestion in additional {
            if let existing = byID[suggestion.id], existing.relevanceScore >= suggestion.relevanceScore {
                continue
            }
            byID[suggestion.id] = suggestion
        }
        return byID.values.sorted {
            if $0.relevanceScore == $1.relevanceScore {
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            return $0.relevanceScore > $1.relevanceScore
        }
    }

    private struct DirectoryAggregate {
        var childCount: Int = 0
        var bestScore: Double = 0
        var scoreSum: Double = 0
        var latestTimestamp: Date?
        var risk: RetrievalRiskLabel = .low
        var previewTitles: [String] = []
    }

    private nonisolated static func directorySuggestions(
        query: String,
        suggestions: [RetrievalSuggestion],
        typingMode: Bool
    ) -> [RetrievalSuggestion] {
        let queryTokens = informativeQueryTokens(query)
        let queryAcronymTokens = acronymTokens(query)
        let hasDirectoryIntent = !queryTokens.isDisjoint(with: DirectorySuggestionTuning.queryIntentTerms)
        let seedLimit = typingMode
            ? DirectorySuggestionTuning.typingSeedSuggestions
            : DirectorySuggestionTuning.deepSeedSuggestions
        let maxSuggestions = typingMode
            ? DirectorySuggestionTuning.typingMaxSuggestions
            : DirectorySuggestionTuning.deepMaxSuggestions
        let minimumScore = typingMode
            ? DirectorySuggestionTuning.typingMinimumScore
            : DirectorySuggestionTuning.deepMinimumScore

        var aggregates: [String: DirectoryAggregate] = [:]
        for suggestion in suggestions.prefix(seedLimit) {
            guard suggestion.sourceType == .file else { continue }
            let path = suggestion.sourcePathOrHandle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.hasPrefix("/") else { continue }
            let imagePath = isImagePath(path)
            if imagePath && !(hasDirectoryIntent && pathHasCueSegment(path)) {
                continue
            }
            let directoryPaths = candidateDirectoryPaths(
                for: path,
                queryTokens: queryTokens,
                hasDirectoryIntent: hasDirectoryIntent
            )
            guard !directoryPaths.isEmpty else { continue }
            for directoryPath in directoryPaths {
                var aggregate = aggregates[directoryPath] ?? DirectoryAggregate()
                aggregate.childCount += 1
                aggregate.bestScore = max(aggregate.bestScore, suggestion.relevanceScore)
                aggregate.scoreSum += suggestion.relevanceScore
                aggregate.latestTimestamp = maxTimestamp(aggregate.latestTimestamp, suggestion.timestamp)
                aggregate.risk = higherRisk(aggregate.risk, suggestion.risk)
                if aggregate.previewTitles.count < 3 {
                    let compactTitle = suggestion.title
                        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !compactTitle.isEmpty && !aggregate.previewTitles.contains(compactTitle) {
                        aggregate.previewTitles.append(compactTitle)
                    }
                }
                aggregates[directoryPath] = aggregate
            }
        }

        var output: [RetrievalSuggestion] = []
        for (directoryPath, aggregate) in aggregates {
            guard aggregate.childCount > 0 else { continue }
            let averageScore = aggregate.scoreSum / Double(aggregate.childCount)
            let pathCoverage = tokenCoverage(tokens: queryTokens, text: directoryPath)
            let lowerPath = directoryPath.lowercased()
            let pathTokens = Set(tokenize(directoryPath))
            var cueBoost: Double = 0
            if lowerPath.contains("/docs/") || lowerPath.hasSuffix("/docs") {
                cueBoost += 0.22
            }
            if lowerPath.contains("template") {
                cueBoost += 0.22
            }
            if lowerPath.contains("template") && !queryAcronymTokens.isDisjoint(with: pathTokens) {
                cueBoost += 0.32
            }
            if lowerPath.contains("/examples/") || lowerPath.contains("/samples/") {
                cueBoost += 0.08
            }
            let clusterBoost = min(0.28, Double(max(0, aggregate.childCount - 1)) * 0.06)
            let intentBoost = hasDirectoryIntent ? 0.08 : 0
            let score = max(aggregate.bestScore * 0.8, averageScore * 0.95)
                + pathCoverage * 0.35
                + cueBoost
                + clusterBoost
                + intentBoost
            let hasEvidence = aggregate.childCount >= (hasDirectoryIntent ? 1 : 2)
                || pathCoverage >= 0.22
                || cueBoost >= 0.2
            guard hasEvidence, score >= minimumScore else { continue }

            let directoryURL = URL(fileURLWithPath: directoryPath)
            let basename = directoryURL.lastPathComponent
            let title = basename.isEmpty ? directoryPath : "\(basename)/"
            let snippet: String
            if aggregate.previewTitles.isEmpty {
                snippet = "Directory with \(aggregate.childCount) related files."
            } else {
                snippet = "Directory with \(aggregate.childCount) related files: \(aggregate.previewTitles.joined(separator: ", "))"
            }
            output.append(
                RetrievalSuggestion(
                    id: "dir:\(directoryPath)",
                    sourceType: .file,
                    title: title,
                    snippet: String(snippet.prefix(420)),
                    sourceId: directoryPath,
                    sourcePathOrHandle: directoryPath,
                    relevanceScore: score,
                    risk: aggregate.risk,
                    reasons: ["directory", "directory-cluster"],
                    timestamp: aggregate.latestTimestamp
                )
            )
        }

        return output
            .sorted {
                if $0.relevanceScore == $1.relevanceScore {
                    return $0.title.localizedStandardCompare($1.title) == .orderedAscending
                }
                return $0.relevanceScore > $1.relevanceScore
            }
            .prefix(maxSuggestions)
            .map { $0 }
    }

    private nonisolated static func candidateDirectoryPaths(
        for filePath: String,
        queryTokens: Set<String>,
        hasDirectoryIntent: Bool
    ) -> [String] {
        let fileURL = URL(fileURLWithPath: filePath)
        let parentURL = fileURL.deletingLastPathComponent()
        let parentPath = parentURL.path
        guard !parentPath.isEmpty, parentPath != "/" else { return [] }

        var candidates: [String] = [parentPath]
        var seen: Set<String> = [parentPath]

        var cursor = parentURL
        var steps = 0
        while cursor.path != "/" && steps < 8 {
            let name = cursor.lastPathComponent.lowercased()
            if name.isEmpty {
                break
            }
            let nameTokens = Set(tokenize(name))
            let cueMatch = DirectorySuggestionTuning.cueSegments.contains(name)
                || DirectorySuggestionTuning.cueSegments.contains(where: { name.contains($0) })
            let queryOverlap = !nameTokens.isDisjoint(with: queryTokens)
            if cueMatch || (hasDirectoryIntent && queryOverlap) {
                if !seen.contains(cursor.path) {
                    candidates.append(cursor.path)
                    seen.insert(cursor.path)
                }
            }
            let next = cursor.deletingLastPathComponent()
            if next.path == cursor.path {
                break
            }
            cursor = next
            steps += 1
        }
        return candidates
    }

    private nonisolated static func informativeQueryTokens(_ text: String) -> Set<String> {
        Set(tokenize(text).filter { token in
            if token.count >= 3 {
                return !QueryTuning.stopWords.contains(token)
            }
            return token.count >= 2 && token.contains(where: \.isNumber)
        })
    }

    private nonisolated static func tokenize(_ text: String) -> [String] {
        text
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    private nonisolated static func acronymTokens(_ text: String) -> Set<String> {
        Set(
            text
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .compactMap { token -> String? in
                    guard token.count >= 2 else { return nil }
                    let hasUppercase = token.contains(where: \.isUppercase)
                    let hasLowercase = token.contains(where: \.isLowercase)
                    let hasLetter = token.contains(where: \.isLetter)
                    guard hasLetter, hasUppercase, !hasLowercase else { return nil }
                    return token.lowercased()
                }
        )
    }

    private nonisolated static func tokenCoverage(tokens: Set<String>, text: String) -> Double {
        guard !tokens.isEmpty else { return 0 }
        let textTokens = Set(tokenize(text))
        guard !textTokens.isEmpty else { return 0 }
        let overlap = tokens.intersection(textTokens).count
        return Double(overlap) / Double(tokens.count)
    }

    private nonisolated static func isImagePath(_ path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        return DirectorySuggestionTuning.imageExtensions.contains(ext)
    }

    private nonisolated static func pathHasCueSegment(_ path: String) -> Bool {
        let segments = path
            .lowercased()
            .split(separator: "/")
            .map(String.init)
        return segments.contains(where: { segment in
            DirectorySuggestionTuning.cueSegments.contains(segment)
                || DirectorySuggestionTuning.cueSegments.contains(where: { segment.contains($0) })
        })
    }

    private nonisolated static func higherRisk(
        _ lhs: RetrievalRiskLabel,
        _ rhs: RetrievalRiskLabel
    ) -> RetrievalRiskLabel {
        let rank: [RetrievalRiskLabel: Int] = [.low: 0, .medium: 1, .high: 2]
        return (rank[rhs] ?? 0) > (rank[lhs] ?? 0) ? rhs : lhs
    }

    private nonisolated static func maxTimestamp(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (l?, r?):
            return l >= r ? l : r
        case let (l?, nil):
            return l
        case let (nil, r?):
            return r
        case (nil, nil):
            return nil
        }
    }
}
