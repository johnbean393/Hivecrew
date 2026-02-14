import Foundation
import HivecrewRetrievalProtocol

public actor LocalReranker {
    public init() {}

    public func rerank(
        query: String,
        suggestions: [RetrievalSuggestion],
        typingMode: Bool
    ) -> [RetrievalSuggestion] {
        let topK = typingMode ? 80 : 600
        let queryTokens = Set(informativeQueryTokens(query))
        let queryAnchorTokens = Set(anchorTokens(query))
        return suggestions
            .prefix(topK)
            .map { suggestion in
                let titleOverlap = overlap(tokens: queryTokens, text: suggestion.title)
                let snippetOverlap = overlap(tokens: queryTokens, text: suggestion.snippet)
                let pathOverlap = overlap(tokens: queryTokens, text: suggestion.sourcePathOrHandle)
                let anchorCoverage = overlap(tokens: queryAnchorTokens, text: "\(suggestion.title) \(suggestion.sourcePathOrHandle)")
                let recencyBoost = suggestion.timestamp.map { max(0, 1 - min(1, Date().timeIntervalSince($0) / 604_800)) } ?? 0
                let evidence = max(titleOverlap, snippetOverlap, pathOverlap, anchorCoverage)
                let vectorOnlyPenalty: Double
                if suggestion.reasons.contains("vector"),
                   !suggestion.reasons.contains("lexical"),
                   evidence < 0.08
                {
                    vectorOnlyPenalty = 0.24
                } else {
                    vectorOnlyPenalty = 0
                }
                let preferredPathBoost = preferredKnowledgePathBoost(
                    path: suggestion.sourcePathOrHandle,
                    anchorTokens: queryAnchorTokens
                )
                let noisePenalty = ephemeralOutputPenalty(for: suggestion.sourcePathOrHandle)
                let rerank = suggestion.relevanceScore
                    + titleOverlap * 0.2
                    + snippetOverlap * 0.26
                    + pathOverlap * 0.42
                    + anchorCoverage * 0.5
                    + preferredPathBoost
                    + recencyBoost * 0.04
                    - vectorOnlyPenalty
                    - noisePenalty
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

    private func informativeQueryTokens(_ text: String) -> [String] {
        tokenize(text).filter { token in
            if token.count >= 3 {
                return !stopWords.contains(token)
            }
            return token.count >= 2 && token.contains(where: \.isNumber)
        }
    }

    private func anchorTokens(_ text: String) -> [String] {
        let genericAcronymStopWords: Set<String> = [
            "pdf", "ppt", "pptx", "doc", "docx", "xls", "xlsx",
            "csv", "tsv", "json", "xml", "txt", "md", "rtf",
            "png", "jpg", "jpeg", "gif", "webp",
        ]
        let rawTokens = text
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        var seen = Set<String>()
        var output: [String] = []
        for (index, token) in rawTokens.enumerated() {
            guard !token.isEmpty else { continue }
            let normalized = token.lowercased()
            guard !stopWords.contains(normalized) else { continue }
            let hasDigit = token.contains(where: \.isNumber)
            let hasLetter = token.contains(where: \.isLetter)
            let hasUppercase = token.contains(where: \.isUppercase)
            let hasLowercase = token.contains(where: \.isLowercase)
            let isUppercaseAcronym = hasLetter
                && hasUppercase
                && !hasLowercase
                && token.count >= 2
                && !genericAcronymStopWords.contains(normalized)
            let cueToken = normalized == "template"
                || normalized == "templates"
                || normalized == "docs"
                || normalized == "documentation"
                || normalized == "readme"
            if (hasDigit && hasLetter)
                || isUppercaseAcronym
                || cueToken
                || (index > 0 && hasUppercase && hasLowercase && normalized.count >= 3)
            {
                guard !seen.contains(normalized) else { continue }
                seen.insert(normalized)
                output.append(normalized)
            }
        }
        return output
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

    private func ephemeralOutputPenalty(for path: String) -> Double {
        let normalized = path.lowercased()
        if normalized.contains("/tests/output/") || normalized.contains("/test/output/") {
            return 0.36
        }
        if normalized.contains("/testing/") || normalized.contains("/tests/input/") {
            return 0.28
        }
        if normalized.contains("/misc/") {
            return 0.14
        }
        if normalized.contains("/app archives/") {
            return 0.32
        }
        if normalized.contains("/deriveddata/") || normalized.contains("/library/developer/") {
            return 0.2
        }
        return 0
    }

    private func preferredKnowledgePathBoost(path: String, anchorTokens: Set<String>) -> Double {
        guard !path.isEmpty, !anchorTokens.isEmpty else { return 0 }
        let normalized = path.lowercased()
        let segments = Set(
            normalized
                .split(separator: "/")
                .map(String.init)
        )
        let hasAnchorSegment = !anchorTokens.isDisjoint(with: segments)
        guard hasAnchorSegment else { return 0 }

        var boost: Double = 0
        if normalized.contains("/projects/") {
            boost += 0.24
        }
        if normalized.contains("/documentation/") || normalized.contains("/docs/") {
            boost += 0.24
        }
        if normalized.hasSuffix("/readme.md") {
            boost += 0.2
        }
        if normalized.hasSuffix(".md") || normalized.hasSuffix(".pdf") || normalized.hasSuffix(".docx") || normalized.hasSuffix(".pptx") {
            boost += 0.08
        }
        return min(0.56, boost)
    }

    private let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "do", "for", "from",
        "how", "i", "if", "in", "into", "is", "it", "me", "my", "of", "on", "or",
        "our", "please", "so", "that", "the", "their", "them", "there", "these",
        "this", "to", "us", "we", "with", "you", "your",
    ]
}
