//
//  ContextSuggestionDrawerView.swift
//  Hivecrew
//
//  Retrieval-backed context suggestions for task input
//

import Combine
import SwiftUI
import HivecrewLLM
import NaturalLanguage

enum PromptContextMode: String, CaseIterable {
    case fileRef = "fileRef"
    case inlineSnippet = "inlineSnippet"
    case structuredSummary = "structuredSummary"

    var label: String {
        switch self {
        case .fileRef:
            return "Attach File"
        case .inlineSnippet:
            return "Inline Snippet"
        case .structuredSummary:
            return "Structured Summary"
        }
    }
}

struct PromptContextSuggestion: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let sourceType: String
    let title: String
    let snippet: String
    let sourceId: String
    let sourcePathOrHandle: String
    let relevanceScore: Double
    let risk: String
    let reasons: [String]
}

private struct RetrievalSuggestRequestPayload: Encodable, Sendable {
    let query: String
    let sourceFilters: [String]?
    let limit: Int
    let typingMode: Bool
    let includeColdPartitionFallback: Bool
}

private struct RetrievalSuggestResponsePayload: Decodable, Sendable {
    let suggestions: [PromptContextSuggestion]
}

private struct RetrievalCreateContextPackRequestPayload: Encodable, Sendable {
    let query: String
    let selectedSuggestionIds: [String]
    let modeOverrides: [String: String]
}

struct RetrievalContextPackPayload: Decodable, Sendable {
    let id: String
    let attachmentPaths: [String]
    let inlinePromptBlocks: [String]
}

private struct ResourceRelevanceVerdict: Codable, Sendable {
    let id: String
    let isRelevant: Bool
    let confidence: Double?
    let reason: String?
}

private struct ResourceRelevanceVerdicts: Codable, Sendable {
    let verdicts: [ResourceRelevanceVerdict]
}

private struct ResourceRelevanceCandidate: Codable, Sendable {
    let id: String
    let title: String
    let resourceName: String
    let snippet: String
}

@MainActor
final class PromptContextSuggestionProvider: ObservableObject {
    @Published private(set) var suggestions: [PromptContextSuggestion] = []
    @Published private(set) var attachedSuggestions: [PromptContextSuggestion] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?

    private var selectedModesBySuggestionID: [String: PromptContextMode] = [:]
    private var debounceTask: Task<Void, Never>?
    private var latestDraft = ""
    private var activeRequestID = 0
    private var lastDraftEditAt = Date.distantPast
    private weak var workerClientProvider: (any CreateWorkerClientProtocol)?

    func setWorkerClientProvider(_ provider: any CreateWorkerClientProtocol) {
        workerClientProvider = provider
    }

    func updateDraft(_ draft: String) {
        latestDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        lastDraftEditAt = Date()
        debounceTask?.cancel()
        activeRequestID += 1
        let requestID = activeRequestID

        guard !latestDraft.isEmpty else {
            suggestions = []
            lastError = nil
            return
        }

        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self else { return }
            guard !Task.isCancelled else { return }
            await self.fetchSuggestions(for: self.latestDraft, requestID: requestID)
        }
    }

    func isSelected(_ suggestionID: String) -> Bool {
        attachedSuggestions.contains(where: { $0.id == suggestionID })
    }

    func selectedMode(for suggestionID: String, sourceType: String) -> PromptContextMode {
        if let selected = selectedModesBySuggestionID[suggestionID] {
            return selected
        }
        return sourceType == "file" ? .fileRef : .structuredSummary
    }

    func toggleSelection(for suggestion: PromptContextSuggestion) {
        if isSelected(suggestion.id) {
            detachSuggestion(withID: suggestion.id)
        } else {
            attachSuggestion(suggestion)
        }
    }

    func attachSuggestion(_ suggestion: PromptContextSuggestion) {
        guard Self.isSearchableSuggestion(suggestion) else { return }
        guard !attachedSuggestions.contains(where: { $0.id == suggestion.id }) else { return }
        if selectedModesBySuggestionID[suggestion.id] == nil {
            selectedModesBySuggestionID[suggestion.id] = selectedMode(for: suggestion.id, sourceType: suggestion.sourceType)
        }
        attachedSuggestions.append(suggestion)
        suggestions.removeAll { $0.id == suggestion.id }
    }

    func detachSuggestion(withID suggestionID: String) {
        selectedModesBySuggestionID[suggestionID] = nil
        guard let index = attachedSuggestions.firstIndex(where: { $0.id == suggestionID }) else { return }
        let suggestion = attachedSuggestions.remove(at: index)
        if !suggestions.contains(where: { $0.id == suggestionID }) && !latestDraft.isEmpty {
            suggestions.insert(suggestion, at: 0)
        }
    }

    func setMode(_ mode: PromptContextMode, for suggestionID: String) {
        selectedModesBySuggestionID[suggestionID] = mode
    }

    func selectedSuggestionIDs() -> [String] {
        attachedSuggestions.map(\.id)
    }

    func selectedModeOverrides() -> [String: String] {
        let selectedIDs = Set(attachedSuggestions.map(\.id))
        return selectedModesBySuggestionID
            .filter { selectedIDs.contains($0.key) }
            .mapValues { $0.rawValue }
    }

    func selectedFileAttachmentPathsForFallback() -> [String] {
        let selectedIDs = Set(attachedSuggestions.map(\.id))
        let paths = attachedSuggestions.compactMap { suggestion -> String? in
            guard selectedIDs.contains(suggestion.id) else { return nil }
            guard selectedModesBySuggestionID[suggestion.id] == .fileRef else { return nil }
            guard suggestion.sourceType == "file" else { return nil }
            let path = suggestion.sourcePathOrHandle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.hasPrefix("/") else { return nil }
            guard !Self.isImageFilePath(path) else { return nil }
            return path
        }
        return Array(Set(paths)).sorted()
    }

    func createContextPackIfNeeded(query: String) async throws -> RetrievalContextPackPayload? {
        let selectedIds = selectedSuggestionIDs()
        guard !selectedIds.isEmpty else { return nil }
        let payload = RetrievalCreateContextPackRequestPayload(
            query: query,
            selectedSuggestionIds: selectedIds,
            modeOverrides: selectedModeOverrides()
        )
        return try await Self.postJSON(
            path: "/api/v1/retrieval/context-pack",
            request: payload,
            responseType: RetrievalContextPackPayload.self
        )
    }

    func clearAfterSubmit() {
        debounceTask?.cancel()
        activeRequestID += 1
        selectedModesBySuggestionID = [:]
        suggestions = []
        attachedSuggestions = []
        lastError = nil
        latestDraft = ""
    }

    private func fetchSuggestions(for query: String, requestID: Int) async {
        isLoading = true
        var loadingCompleted = false
        defer {
            if !loadingCompleted {
                isLoading = false
            }
        }

        do {
            let pipelineStart = Date()
            let nlpStart = Date()
            let queryKeywords = Self.strictKeywords(from: query)
            let retrievalQuery = Self.compactRetrievalQuery(from: query)
            let retrievalQueryKeywords = Self.strictKeywords(from: retrievalQuery)
            let shouldRunDeepBase = Self.shouldRunDeepBaseQuery(query: retrievalQuery, queryKeywords: retrievalQueryKeywords)
            let shouldRunExpansions = Self.shouldRunExpansionQueries(query: retrievalQuery, queryKeywords: retrievalQueryKeywords)
            let additionalQueries = shouldRunExpansions
                ? Self.generateNLPQueryExpansions(from: retrievalQuery, limit: Self.maximumExpansionQueryCount)
                : []
            let nlpDurationMs = Int(Date().timeIntervalSince(nlpStart) * 1_000)

            let retrievalStart = Date()
            let fastBaseSuggestions = await Self.retrieveSuggestionsBestEffort(query: retrievalQuery, profile: Self.primaryFastProfile)
            var mergedSuggestions = fastBaseSuggestions
            var retrievalRequestCount = 1
            if shouldRunDeepBase, fastBaseSuggestions.count < Self.fastBaseSufficientCandidateCount {
                let deepBaseSuggestions = await Self.retrieveSuggestionsBestEffort(query: retrievalQuery, profile: Self.primaryDeepProfile)
                mergedSuggestions.append(contentsOf: deepBaseSuggestions)
                retrievalRequestCount += 1
            }
            let baseSuggestionIDs = Set(mergedSuggestions.map(\.id))
            if !additionalQueries.isEmpty, mergedSuggestions.count < Self.expansionCandidateCutoff {
                let fastExpansionSuggestions = await retrieveSuggestionsInParallelBestEffort(
                    queries: additionalQueries,
                    profile: Self.expansionFastProfile
                )
                mergedSuggestions.append(contentsOf: fastExpansionSuggestions)
                retrievalRequestCount += additionalQueries.count
            }
            let searchableSuggestions = mergedSuggestions.filter(Self.isSearchableSuggestion(_:))
            let dedupedSuggestions = Self.dedupeSuggestions(searchableSuggestions)
            let penalizedSuggestions = Self.applyExpansionOnlyPenalty(
                dedupedSuggestions,
                baseSuggestionIDs: baseSuggestionIDs
            )
            let rankedSuggestions = Self.rankSuggestionsWithBasePreference(
                penalizedSuggestions,
                baseSuggestionIDs: baseSuggestionIDs
            )
            let candidateSuggestions = Array(rankedSuggestions.prefix(18))
            let expansionOnlyCandidateCount = candidateSuggestions.filter { !baseSuggestionIDs.contains($0.id) }.count
            let retrievalDurationMs = Int(Date().timeIntervalSince(retrievalStart) * 1_000)
            try Task.checkCancellation()

            // Surface best candidates immediately for low latency.
            guard requestID == activeRequestID, query == latestDraft else { return }
            let selectedIDs = Set(attachedSuggestions.map(\.id))
            let preliminaryByID = Dictionary(uniqueKeysWithValues: candidateSuggestions.map { ($0.id, $0) })
            attachedSuggestions = attachedSuggestions.map { preliminaryByID[$0.id] ?? $0 }
            suggestions = candidateSuggestions.filter { !selectedIDs.contains($0.id) }
            lastError = nil
            isLoading = false
            loadingCompleted = true

            let relevanceStart = Date()
            var relevantSuggestions: [PromptContextSuggestion]
            let shouldRunRelevanceStage = Self.shouldRunLLMRelevanceStage(
                query: query,
                candidateCount: candidateSuggestions.count,
                queryKeywords: queryKeywords
            )
            var ranLLMRelevance = false
            if shouldRunRelevanceStage {
                let idleMs = Date().timeIntervalSince(lastDraftEditAt) * 1_000
                let waitMs = max(Self.relevanceStabilizationDelayMs, UInt64(max(0, Self.minimumIdleBeforeLLMRelevanceMs - idleMs)))
                if waitMs > 0 {
                    try? await Task.sleep(for: .milliseconds(waitMs))
                }
                guard requestID == activeRequestID, query == latestDraft else { return }
                do {
                    let workerClient = try await createWorkerClient()
                    let relevantSuggestionIDs = try await filterRelevantSuggestionIDs(
                        for: query,
                        candidates: candidateSuggestions,
                        using: workerClient
                    )
                    let relevantIDSet = Set(relevantSuggestionIDs)
                    relevantSuggestions = candidateSuggestions.filter { relevantIDSet.contains($0.id) }
                    ranLLMRelevance = true
                } catch {
                    // Relevance stage is additive; keep preliminary suggestions on failure.
                    print("PromptContextSuggestionProvider: Relevance check fallback: \(error.localizedDescription)")
                    relevantSuggestions = candidateSuggestions
                }
            } else {
                relevantSuggestions = candidateSuggestions
            }
            var fallbackAdmissions = 0
            // Keep fallback conservative. Prefer fewer strong matches over filling weak ones.
            if relevantSuggestions.isEmpty {
                let existingIDs = Set(relevantSuggestions.map(\.id))
                let needed = min(3, candidateSuggestions.count)
                let fallbackCandidates = Self.relevanceFallbackCandidates(
                    query: query,
                    candidates: candidateSuggestions,
                    excluding: existingIDs,
                    limit: needed
                )
                fallbackAdmissions = fallbackCandidates.count
                relevantSuggestions.append(contentsOf: fallbackCandidates)
                relevantSuggestions = Self.dedupeSuggestions(relevantSuggestions)
            }
            relevantSuggestions = Self.rankSuggestionsWithBasePreference(
                relevantSuggestions,
                baseSuggestionIDs: baseSuggestionIDs
            )
            let expansionOnlyRelevantCount = relevantSuggestions.filter { !baseSuggestionIDs.contains($0.id) }.count
            let relevanceDurationMs = Int(Date().timeIntervalSince(relevanceStart) * 1_000)
            try Task.checkCancellation()

            guard requestID == activeRequestID, query == latestDraft else { return }
            let refreshedByID = Dictionary(uniqueKeysWithValues: relevantSuggestions.map { ($0.id, $0) })
            attachedSuggestions = attachedSuggestions.map { refreshedByID[$0.id] ?? $0 }
            suggestions = relevantSuggestions.filter { !selectedIDs.contains($0.id) }
            lastError = nil
            let totalDurationMs = Int(Date().timeIntervalSince(pipelineStart) * 1_000)
            print(
                "PromptContextSuggestionProvider: NLP pipeline \(totalDurationMs)ms " +
                    "[nlp=\(nlpDurationMs)ms, retrieval=\(retrievalDurationMs)ms, relevance=\(relevanceDurationMs)ms, " +
                    "queryChars=\(query.count), retrievalQueryChars=\(retrievalQuery.count), " +
                    "queries=\(retrievalRequestCount), deepBase=\(shouldRunDeepBase), expansions=\(additionalQueries.count), " +
                    "llmRelevance=\(ranLLMRelevance), " +
                    "candidates=\(candidateSuggestions.count), relevant=\(relevantSuggestions.count), " +
                    "fallbackAdmissions=\(fallbackAdmissions), expansionOnlyCandidates=\(expansionOnlyCandidateCount), " +
                    "expansionOnlyRelevant=\(expansionOnlyRelevantCount)]"
            )
        } catch is CancellationError {
            // Ignore stale/cancelled requests.
        } catch {
            guard requestID == activeRequestID else { return }
            suggestions = []
            lastError = error.localizedDescription
        }
    }

    private func createWorkerClient() async throws -> any LLMClientProtocol {
        guard let workerClientProvider else {
            throw TaskServiceError.workerModelNotConfigured
        }
        return try await workerClientProvider.createWorkerLLMClient(
            fallbackProviderId: "",
            fallbackModelId: ""
        )
    }

    private nonisolated static let nlpStopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "do", "for", "from",
        "how", "i", "if", "in", "into", "is", "it", "me", "my", "of", "on", "or",
        "our", "please", "so", "that", "the", "their", "them", "there", "these",
        "this", "to", "us", "we", "with", "you", "your"
    ]
    private nonisolated static let disallowedImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif", "heic", "heif",
        "avif", "ico", "icns", "svg", "psd", "raw", "cr2", "nef", "dng", "arw"
    ]
    private struct RetrievalQueryProfile: Sendable {
        let limit: Int
        let typingMode: Bool
        let includeColdPartitionFallback: Bool
        let timeoutSeconds: TimeInterval
    }
    private nonisolated static let primaryFastProfile = RetrievalQueryProfile(
        limit: 12,
        typingMode: true,
        includeColdPartitionFallback: false,
        timeoutSeconds: 1.2
    )
    private nonisolated static let primaryDeepProfile = RetrievalQueryProfile(
        limit: 16,
        typingMode: false,
        includeColdPartitionFallback: true,
        timeoutSeconds: 1.8
    )
    private nonisolated static let expansionFastProfile = RetrievalQueryProfile(
        limit: 6,
        typingMode: true,
        includeColdPartitionFallback: true,
        timeoutSeconds: 1.4
    )
    private nonisolated static let minimumCharactersForDeepBase = 32
    private nonisolated static let minimumKeywordCountForDeepBase = 3
    private nonisolated static let minimumCharactersForExpansion = 56
    private nonisolated static let minimumKeywordCountForExpansion = 4
    private nonisolated static let maximumExpansionQueryCount = 1
    private nonisolated static let fastBaseSufficientCandidateCount = 8
    private nonisolated static let expansionCandidateCutoff = 12
    private nonisolated static let minimumCharactersForLLMRelevance = 40
    private nonisolated static let minimumCandidatesForLLMRelevance = 4
    private nonisolated static let relevanceStabilizationDelayMs: UInt64 = 220
    private nonisolated static let minimumIdleBeforeLLMRelevanceMs: Double = 650
    private nonisolated static let compactQueryMinimumLength = 180
    private nonisolated static let compactQueryMaximumLength = 260
    private nonisolated static let compactQueryMaxKeywordTerms = 14
    // Kept enabled: final relevance verification refines precision after fast retrieval.
    private nonisolated static let llmRelevanceEnabled = true
    private nonisolated static let retrievalTimeoutRetryAttempts = 1
    private nonisolated static let retrievalTimeoutRetryDelayMs: UInt64 = 140
    private nonisolated static let retrievalTimeoutRetryExtraSeconds: TimeInterval = 0.3

    private nonisolated static let strictRelevanceMinimumConfidence: Double = 0.72
    private nonisolated static let strictRelevanceMinimumKeywordOverlap: Double = 0.10
    private nonisolated static let strictRelevanceHighConfidenceOverride: Double = 0.90
    private nonisolated static let strictRelevanceHighConfidenceMinimumOverlap: Double = 0.05
    private nonisolated static let strictRelevanceFallbackConfidenceOnly: Double = 0.82
    private nonisolated static let relevanceFallbackMinimumKeywordOverlap: Double = 0.12
    private nonisolated static let relevanceFallbackMinimumScore: Double = 0.24
    private nonisolated static let expansionOnlyPenaltyScore: Double = 0.09
    private nonisolated static let baseSuggestionTieBreakDelta: Double = 0.05

    private nonisolated static func generateNLPQueryExpansions(from query: String, limit: Int) -> [String] {
        let cleaned = query
            .replacingOccurrences(of: "[^\\p{L}\\p{N}\\s_-]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }

        var nounTokens: [String] = []
        var verbTokens: [String] = []
        var adjectiveTokens: [String] = []
        var keywordTokens: [String] = []

        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = cleaned
        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .joinNames, .omitOther]
        tagger.enumerateTags(
            in: cleaned.startIndex..<cleaned.endIndex,
            unit: .word,
            scheme: .lexicalClass,
            options: options
        ) { tag, tokenRange in
            let token = String(cleaned[tokenRange]).lowercased()
            guard token.count >= 3 else { return true }
            guard !Self.nlpStopWords.contains(token) else { return true }
            keywordTokens.append(token)
            switch tag {
            case .noun:
                nounTokens.append(token)
            case .verb:
                verbTokens.append(token)
            case .adjective:
                adjectiveTokens.append(token)
            default:
                break
            }
            return true
        }

        if keywordTokens.isEmpty {
            keywordTokens = cleaned.lowercased().split(separator: " ").map(String.init).filter { token in
                token.count >= 3 && !Self.nlpStopWords.contains(token)
            }
        }

        let uniqueNouns = Self.uniqueOrdered(nounTokens)
        let uniqueVerbs = Self.uniqueOrdered(verbTokens)
        let uniqueAdjectives = Self.uniqueOrdered(adjectiveTokens)
        let uniqueKeywords = Self.uniqueOrdered(keywordTokens)

        var expandedQueries: [String] = []
        if !uniqueNouns.isEmpty {
            expandedQueries.append(uniqueNouns.prefix(6).joined(separator: " "))
        }
        let nounVerbBlend = Self.uniqueOrdered(uniqueNouns + uniqueVerbs)
        if nounVerbBlend.count > 1 {
            expandedQueries.append(nounVerbBlend.prefix(6).joined(separator: " "))
        }
        let intentBlend = Self.uniqueOrdered(uniqueNouns + uniqueAdjectives + uniqueKeywords)
        if intentBlend.count > 1 {
            expandedQueries.append(intentBlend.prefix(8).joined(separator: " "))
        }
        if uniqueKeywords.count > 2 {
            expandedQueries.append(uniqueKeywords.prefix(3).joined(separator: " "))
        }

        return Self.uniqueQueries(
            expandedQueries.filter { $0.caseInsensitiveCompare(cleaned) != .orderedSame },
            limit: limit
        )
    }

    private nonisolated static func strictKeywords(from text: String) -> Set<String> {
        let cleaned = text
            .replacingOccurrences(of: "[^\\p{L}\\p{N}\\s_-]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !cleaned.isEmpty else { return [] }
        let keywords = cleaned.split(separator: " ").map(String.init).filter { token in
            token.count >= 3 && !Self.nlpStopWords.contains(token)
        }
        return Set(keywords)
    }

    private nonisolated static func compactRetrievalQuery(from text: String) -> String {
        let cleaned = text
            .replacingOccurrences(of: "[^\\p{L}\\p{N}\\s_-]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return text }
        guard cleaned.count >= compactQueryMinimumLength else { return cleaned }

        let orderedKeywords = cleaned
            .lowercased()
            .split(separator: " ")
            .map(String.init)
            .filter { token in
                token.count >= 3 && !nlpStopWords.contains(token)
            }
        let compactKeywords = uniqueOrdered(orderedKeywords).prefix(compactQueryMaxKeywordTerms).joined(separator: " ")
        if compactKeywords.count >= 24 {
            return compactKeywords
        }
        return String(cleaned.prefix(compactQueryMaximumLength))
    }

    private nonisolated static func keywordOverlapScore(
        queryKeywords: Set<String>,
        candidateText: String
    ) -> Double {
        guard !queryKeywords.isEmpty else { return 0 }
        let candidateKeywords = strictKeywords(from: candidateText)
        guard !candidateKeywords.isEmpty else { return 0 }
        let shared = queryKeywords.intersection(candidateKeywords).count
        return Double(shared) / Double(queryKeywords.count)
    }

    private nonisolated static func shouldRunDeepBaseQuery(
        query: String,
        queryKeywords: Set<String>
    ) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= minimumCharactersForDeepBase || queryKeywords.count >= minimumKeywordCountForDeepBase
    }

    private nonisolated static func shouldRunExpansionQueries(
        query: String,
        queryKeywords: Set<String>
    ) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= minimumCharactersForExpansion && queryKeywords.count >= minimumKeywordCountForExpansion
    }

    private nonisolated static func shouldRunLLMRelevanceStage(
        query: String,
        candidateCount: Int,
        queryKeywords: Set<String>
    ) -> Bool {
        guard llmRelevanceEnabled else { return false }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumCharactersForLLMRelevance else { return false }
        guard candidateCount >= minimumCandidatesForLLMRelevance else { return false }
        return queryKeywords.count >= minimumKeywordCountForDeepBase
    }

    private func filterRelevantSuggestionIDs(
        for query: String,
        candidates: [PromptContextSuggestion],
        using client: any LLMClientProtocol
    ) async throws -> [String] {
        guard !candidates.isEmpty else { return [] }
        let payload = candidates.map {
            ResourceRelevanceCandidate(
                id: $0.id,
                title: $0.title,
                resourceName: $0.sourcePathOrHandle,
                snippet: String($0.snippet.prefix(320))
            )
        }
        let candidatesByID = Dictionary(uniqueKeysWithValues: payload.map { ($0.id, $0) })
        let queryKeywords = Self.strictKeywords(from: query)
        let payloadData = try JSONEncoder().encode(payload)
        let payloadJSONString = String(decoding: payloadData, as: UTF8.self)

        let systemMessage = LLMMessage.system(
            """
            You are a relevance gate for retrieval results.
            Use only the provided resource name and snippet.
            Mark a resource relevant when it is likely useful to execute the prompt.
            Allow moderately related resources if they clearly share key entities, topics, filenames, or deliverable intent.
            Respond with strict JSON only.
            """
        )
        let userMessage = LLMMessage.user(
            """
            User prompt:
            \(query)

            Resource candidates (JSON):
            \(payloadJSONString)

            Rules:
            - Be precision-first, but do not reject all moderately relevant resources.
            - Set isRelevant=true for direct matches and clear high-signal adjacent matches.
            - Confidence must be 0.0 to 1.0 and should reflect evidence strength.
            - reason should be concise and reference concrete overlap (keywords, file intent, or artifact type).

            Return:
            {"verdicts":[{"id":"...","isRelevant":true,"confidence":0.0,"reason":"..."}]}
            """
        )
        let response = try await client.chat(messages: [systemMessage, userMessage], tools: nil)
        guard let text = response.text else { return [] }
        guard let jsonData = Self.extractJSON(from: text).data(using: .utf8) else {
            return []
        }
        let verdicts = try JSONDecoder().decode(ResourceRelevanceVerdicts.self, from: jsonData)
        return verdicts.verdicts.compactMap { verdict in
            guard verdict.isRelevant else { return nil }
            let confidence = min(max(verdict.confidence ?? 0, 0), 1)
            guard confidence >= Self.strictRelevanceMinimumConfidence else { return nil }
            guard let candidate = candidatesByID[verdict.id] else { return nil }

            if queryKeywords.isEmpty {
                return confidence >= Self.strictRelevanceFallbackConfidenceOnly ? verdict.id : nil
            }

            let overlap = Self.keywordOverlapScore(
                queryKeywords: queryKeywords,
                candidateText: "\(candidate.title) \(candidate.resourceName) \(candidate.snippet)"
            )

            if overlap >= Self.strictRelevanceMinimumKeywordOverlap {
                return verdict.id
            }
            if confidence >= Self.strictRelevanceHighConfidenceOverride,
               overlap >= Self.strictRelevanceHighConfidenceMinimumOverlap {
                return verdict.id
            }
            return nil
        }
    }

    private func retrieveSuggestionsInParallelBestEffort(
        queries: [String],
        profile: RetrievalQueryProfile
    ) async -> [PromptContextSuggestion] {
        return await withTaskGroup(of: [PromptContextSuggestion].self) { group in
            for query in queries {
                group.addTask {
                    await Self.retrieveSuggestionsBestEffort(query: query, profile: profile)
                }
            }
            var merged: [PromptContextSuggestion] = []
            for await result in group {
                merged.append(contentsOf: result)
            }
            return merged
        }
    }

    private nonisolated static func retrieveSuggestions(
        query: String,
        profile: RetrievalQueryProfile
    ) async throws -> [PromptContextSuggestion] {
        let response = try await postJSON(
            path: "/api/v1/retrieval/suggest",
            request: RetrievalSuggestRequestPayload(
                query: query,
                sourceFilters: nil,
                limit: profile.limit,
                typingMode: profile.typingMode,
                includeColdPartitionFallback: profile.includeColdPartitionFallback
            ),
            responseType: RetrievalSuggestResponsePayload.self,
            requestTimeoutSeconds: profile.timeoutSeconds
        )
        return response.suggestions
    }

    private nonisolated static func retrieveSuggestionsBestEffort(
        query: String,
        profile: RetrievalQueryProfile
    ) async -> [PromptContextSuggestion] {
        var attempt = 0
        var currentProfile = profile
        while true {
            do {
                return try await retrieveSuggestions(query: query, profile: currentProfile)
            } catch {
                if Task.isCancelled {
                    return []
                }
                guard isTimeoutError(error),
                      attempt < retrievalTimeoutRetryAttempts else {
                    print("PromptContextSuggestionProvider: Retrieval request failed for query '\(query)': \(error.localizedDescription)")
                    return []
                }
                attempt += 1
                currentProfile = RetrievalQueryProfile(
                    limit: currentProfile.limit,
                    typingMode: currentProfile.typingMode,
                    includeColdPartitionFallback: currentProfile.includeColdPartitionFallback,
                    timeoutSeconds: currentProfile.timeoutSeconds + retrievalTimeoutRetryExtraSeconds
                )
                try? await Task.sleep(for: .milliseconds(retrievalTimeoutRetryDelayMs))
            }
        }
    }

    private nonisolated static func isTimeoutError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
            return true
        }
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return true
        }
        return nsError.localizedDescription.localizedCaseInsensitiveContains("timed out")
    }

    private nonisolated static func uniqueQueries(_ queries: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for query in queries {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(trimmed)
            if result.count >= limit {
                break
            }
        }
        return result
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

    private nonisolated static func isImageFilePath(_ pathOrHandle: String) -> Bool {
        let trimmed = pathOrHandle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let ext = URL(fileURLWithPath: trimmed).pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        return disallowedImageExtensions.contains(ext)
    }

    private nonisolated static func isSearchableSuggestion(_ suggestion: PromptContextSuggestion) -> Bool {
        guard suggestion.sourceType.caseInsensitiveCompare("file") == .orderedSame else { return true }
        if isImageFilePath(suggestion.sourcePathOrHandle) {
            return false
        }
        if isImageFilePath(suggestion.title) {
            return false
        }
        return true
    }

    private nonisolated static func dedupeSuggestions(_ suggestions: [PromptContextSuggestion]) -> [PromptContextSuggestion] {
        var byID: [String: PromptContextSuggestion] = [:]
        for suggestion in suggestions {
            if let existing = byID[suggestion.id], existing.relevanceScore >= suggestion.relevanceScore {
                continue
            }
            byID[suggestion.id] = suggestion
        }
        return byID.values.sorted { $0.relevanceScore > $1.relevanceScore }
    }

    private nonisolated static func applyExpansionOnlyPenalty(
        _ suggestions: [PromptContextSuggestion],
        baseSuggestionIDs: Set<String>
    ) -> [PromptContextSuggestion] {
        suggestions.map { suggestion in
            guard !baseSuggestionIDs.contains(suggestion.id) else { return suggestion }
            return PromptContextSuggestion(
                id: suggestion.id,
                sourceType: suggestion.sourceType,
                title: suggestion.title,
                snippet: suggestion.snippet,
                sourceId: suggestion.sourceId,
                sourcePathOrHandle: suggestion.sourcePathOrHandle,
                relevanceScore: max(0, suggestion.relevanceScore - expansionOnlyPenaltyScore),
                risk: suggestion.risk,
                reasons: suggestion.reasons
            )
        }
    }

    private nonisolated static func rankSuggestionsWithBasePreference(
        _ suggestions: [PromptContextSuggestion],
        baseSuggestionIDs: Set<String>
    ) -> [PromptContextSuggestion] {
        suggestions.sorted { lhs, rhs in
            let scoreDelta = abs(lhs.relevanceScore - rhs.relevanceScore)
            if scoreDelta <= baseSuggestionTieBreakDelta {
                let lhsIsBase = baseSuggestionIDs.contains(lhs.id)
                let rhsIsBase = baseSuggestionIDs.contains(rhs.id)
                if lhsIsBase != rhsIsBase {
                    return lhsIsBase
                }
            }
            if lhs.relevanceScore == rhs.relevanceScore {
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            return lhs.relevanceScore > rhs.relevanceScore
        }
    }

    private nonisolated static func relevanceFallbackCandidates(
        query: String,
        candidates: [PromptContextSuggestion],
        excluding: Set<String>,
        limit: Int
    ) -> [PromptContextSuggestion] {
        guard limit > 0 else { return [] }
        let queryKeywords = strictKeywords(from: query)
        var selected: [PromptContextSuggestion] = []
        for candidate in candidates {
            guard !excluding.contains(candidate.id) else { continue }
            let overlap = keywordOverlapScore(
                queryKeywords: queryKeywords,
                candidateText: "\(candidate.title) \(candidate.sourcePathOrHandle) \(candidate.snippet)"
            )
            if overlap >= relevanceFallbackMinimumKeywordOverlap,
               candidate.relevanceScore >= relevanceFallbackMinimumScore
            {
                selected.append(candidate)
            }
            if selected.count >= limit {
                break
            }
        }
        return selected
    }

    private nonisolated static func extractJSON(from text: String) -> String {
        var jsonText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if jsonText.hasPrefix("```json") {
            jsonText = String(jsonText.dropFirst(7))
        } else if jsonText.hasPrefix("```") {
            jsonText = String(jsonText.dropFirst(3))
        }
        if jsonText.hasSuffix("```") {
            jsonText = String(jsonText.dropLast(3))
        }
        jsonText = jsonText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = jsonText.firstIndex(of: "{"),
           let end = jsonText.lastIndex(of: "}") {
            jsonText = String(jsonText[start...end])
        }
        return jsonText
    }

    private nonisolated static func postJSON<RequestBody: Encodable, ResponseBody: Decodable>(
        path: String,
        request: RequestBody,
        responseType: ResponseBody.Type,
        requestTimeoutSeconds: TimeInterval = 1.2
    ) async throws -> ResponseBody {
        let token = try RetrievalDaemonManager.shared.daemonAuthToken()
        let baseURL = RetrievalDaemonManager.shared.daemonBaseURL()

        var urlRequest = URLRequest(url: baseURL.appending(path: path))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(token, forHTTPHeaderField: "X-Retrieval-Token")
        urlRequest.httpBody = try JSONEncoder().encode(request)
        urlRequest.timeoutInterval = requestTimeoutSeconds

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "PromptContextSuggestionProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: "Retrieval daemon request failed"])
        }
        return try JSONDecoder().decode(responseType, from: data)
    }
}

struct ContextSuggestionDrawer: View {
    @ObservedObject var provider: PromptContextSuggestionProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Suggested Context")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if provider.isLoading {
                    ProgressView()
                        .scaleEffect(0.55)
                }
                Spacer()
            }

            if provider.suggestions.isEmpty {
                Text(provider.lastError ?? "Start typing to see retrieval suggestions from your approved local sources.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(provider.suggestions) { suggestion in
                            HStack(alignment: .top, spacing: 8) {
                                Button {
                                    provider.attachSuggestion(suggestion)
                                } label: {
                                    Image(systemName: "circle")
                                        .foregroundStyle(Color.secondary)
                                        .font(.system(size: 15, weight: .medium))
                                }
                                .buttonStyle(.plain)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(suggestion.title)
                                        .font(.caption.weight(.semibold))
                                        .lineLimit(1)
                                    Text(suggestion.snippet)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }

                                Spacer(minLength: 8)

                                Menu(provider.selectedMode(for: suggestion.id, sourceType: suggestion.sourceType).label) {
                                    ForEach(PromptContextMode.allCases, id: \.self) { mode in
                                        Button(mode.label) {
                                            provider.setMode(mode, for: suggestion.id)
                                        }
                                    }
                                }
                                .font(.caption2)
                                .menuStyle(.borderlessButton)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(Color(nsColor: .controlBackgroundColor).opacity(0.85))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
                .frame(maxHeight: 150)
            }
        }
    }
}
