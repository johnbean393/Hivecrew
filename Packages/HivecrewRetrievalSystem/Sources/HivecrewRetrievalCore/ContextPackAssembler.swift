import Foundation
import HivecrewRetrievalProtocol

public actor ContextPackAssembler {
    private let store: RetrievalStore
    private let redactor = RedactionService()

    public init(store: RetrievalStore) {
        self.store = store
    }

    public func build(
        request: RetrievalCreateContextPackRequest,
        availableSuggestions: [RetrievalSuggestion]
    ) async throws -> RetrievalContextPack {
        var byID: [String: RetrievalSuggestion] = [:]
        for suggestion in availableSuggestions {
            byID[suggestion.id] = suggestion
        }

        var items: [RetrievalContextPackItem] = []
        var attachmentPaths: [String] = []
        var inlineBlocks: [String] = []

        for id in request.selectedSuggestionIds {
            guard let suggestion = byID[id] else {
                throw RetrievalCoreError.missingSuggestion(id)
            }
            let mode = request.modeOverrides[id] ?? defaultMode(for: suggestion.sourceType)
            let redactedSnippet = redactor.redact(suggestion.snippet)
            let item = RetrievalContextPackItem(
                sourceType: suggestion.sourceType,
                mode: mode,
                title: suggestion.title,
                text: redactedSnippet,
                filePath: suggestion.sourceType == .file ? suggestion.sourcePathOrHandle : nil,
                metadata: [
                    "sourceId": suggestion.sourceId,
                    "sourcePathOrHandle": suggestion.sourcePathOrHandle,
                    "risk": suggestion.risk.rawValue,
                    "graphScore": String(format: "%.3f", suggestion.graphScore),
                ]
            )
            items.append(item)
            switch mode {
            case .fileRef:
                if let path = item.filePath {
                    attachmentPaths.append(path)
                }
            case .inlineSnippet, .structuredSummary:
                inlineBlocks.append("[\(suggestion.sourceType.rawValue)] \(suggestion.title)\n\(redactedSnippet)")
            }
        }

        let pack = RetrievalContextPack(
            query: request.query,
            items: items,
            attachmentPaths: attachmentPaths,
            inlinePromptBlocks: inlineBlocks
        )
        try await store.saveContextPack(pack)
        try await store.appendAudit(
            kind: "context_pack_created",
            payload: [
                "packId": pack.id,
                "query": request.query,
                "itemCount": "\(pack.items.count)",
            ]
        )
        return pack
    }

    private func defaultMode(for source: RetrievalSourceType) -> RetrievalInjectionMode {
        switch source {
        case .file:
            return .fileRef
        case .email, .message, .calendar:
            return .structuredSummary
        }
    }
}
