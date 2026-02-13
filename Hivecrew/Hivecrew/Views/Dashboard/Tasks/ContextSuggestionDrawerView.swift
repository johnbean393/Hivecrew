//
//  ContextSuggestionDrawerView.swift
//  Hivecrew
//
//  Retrieval-backed context suggestions for task input
//

import Combine
import SwiftUI

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

struct PromptContextSuggestion: Identifiable, Codable, Equatable {
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

private struct RetrievalSuggestRequestPayload: Encodable {
    let query: String
    let sourceFilters: [String]?
    let limit: Int
    let typingMode: Bool
    let includeColdPartitionFallback: Bool
}

private struct RetrievalSuggestResponsePayload: Decodable {
    let suggestions: [PromptContextSuggestion]
}

private struct RetrievalCreateContextPackRequestPayload: Encodable {
    let query: String
    let selectedSuggestionIds: [String]
    let modeOverrides: [String: String]
}

struct RetrievalContextPackPayload: Decodable {
    let id: String
    let attachmentPaths: [String]
    let inlinePromptBlocks: [String]
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

    func updateDraft(_ draft: String) {
        latestDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        debounceTask?.cancel()

        guard !latestDraft.isEmpty else {
            suggestions = []
            lastError = nil
            return
        }

        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard let self else { return }
            guard !Task.isCancelled else { return }
            await self.fetchSuggestions(for: self.latestDraft)
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
        return try await postJSON(
            path: "/api/v1/retrieval/context-pack",
            request: payload,
            responseType: RetrievalContextPackPayload.self
        )
    }

    func clearAfterSubmit() {
        selectedModesBySuggestionID = [:]
        suggestions = []
        attachedSuggestions = []
        lastError = nil
        latestDraft = ""
    }

    private func fetchSuggestions(for query: String) async {
        isLoading = true
        defer { isLoading = false }

        do {
            let response = try await postJSON(
                path: "/api/v1/retrieval/suggest",
                request: RetrievalSuggestRequestPayload(
                    query: query,
                    sourceFilters: nil,
                    limit: 12,
                    typingMode: true,
                    includeColdPartitionFallback: false
                ),
                responseType: RetrievalSuggestResponsePayload.self
            )
            let selectedIDs = Set(attachedSuggestions.map(\.id))
            let refreshedByID = Dictionary(uniqueKeysWithValues: response.suggestions.map { ($0.id, $0) })
            attachedSuggestions = attachedSuggestions.map { refreshedByID[$0.id] ?? $0 }
            suggestions = response.suggestions.filter { !selectedIDs.contains($0.id) }
            lastError = nil
        } catch {
            suggestions = []
            lastError = error.localizedDescription
        }
    }

    private func postJSON<RequestBody: Encodable, ResponseBody: Decodable>(
        path: String,
        request: RequestBody,
        responseType: ResponseBody.Type
    ) async throws -> ResponseBody {
        let token = try RetrievalDaemonManager.shared.daemonAuthToken()
        let baseURL = RetrievalDaemonManager.shared.daemonBaseURL()

        var urlRequest = URLRequest(url: baseURL.appending(path: path))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(token, forHTTPHeaderField: "X-Retrieval-Token")
        urlRequest.httpBody = try JSONEncoder().encode(request)
        urlRequest.timeoutInterval = 1.2

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
