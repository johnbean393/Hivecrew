//
//  VoiceRetrievalModels.swift
//  Hivecrew
//
//  Lightweight DTOs for the voice orchestrator's retrieval daemon calls.
//

import Foundation

// MARK: - File Search Result (UI-facing)

struct VoiceFileSearchResult: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let path: String
    let sourceType: String
    let relevanceScore: Double
    var isSelected: Bool = true
}

// MARK: - Retrieval Daemon Request / Response

struct VoiceRetrievalSuggestRequest: Encodable, Sendable {
    let query: String
    let sourceFilters: [String]?
    let limit: Int
    let typingMode: Bool
    let includeColdPartitionFallback: Bool
}

struct VoiceRetrievalSuggestion: Decodable, Sendable {
    let id: String
    let sourceType: String
    let title: String
    let snippet: String
    let sourcePathOrHandle: String
    let relevanceScore: Double
}

struct VoiceRetrievalSuggestResponse: Decodable, Sendable {
    let suggestions: [VoiceRetrievalSuggestion]
}
