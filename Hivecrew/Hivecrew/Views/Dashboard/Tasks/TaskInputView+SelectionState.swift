import Foundation
import HivecrewLLM
import SwiftUI

extension TaskInputView {
    func restorePersistedModelForSelectedProvider() {
        let restoredModelId = UserDefaults.standard.persistedModelId(for: selectedProviderId) ?? ""
        if selectedModelId != restoredModelId {
            selectedModelId = restoredModelId
        }
    }

    func resolvedExecutionTargets(
        effectiveProviderId: String,
        effectiveModelId: String
    ) -> [(providerId: String, modelId: String, copyCount: Int, reasoningEnabled: Bool?, reasoningEffort: String?, serviceTier: LLMServiceTier?)] {
        if useMultiplePromptModels {
            let deduped = normalizedSelections(
                deduplicatedSelections(multiModelSelections),
                fallbackProviderId: effectiveProviderId
            )
            let targets = deduped
                .filter { !$0.providerId.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty }
                .filter { !$0.modelId.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty }
                .map { selection in
                    (
                        providerId: selection.providerId,
                        modelId: selection.modelId,
                        copyCount: selection.copyCount.rawValue,
                        reasoningEnabled: selection.reasoningEnabled,
                        reasoningEffort: selection.reasoningEffort,
                        serviceTier: selection.serviceTier
                    )
                }
            if !targets.isEmpty {
                return targets
            }
        }

        return [(
            providerId: effectiveProviderId,
            modelId: effectiveModelId,
            copyCount: copyCount.rawValue,
            reasoningEnabled: reasoningEnabled,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier
        )]
    }

    func deduplicatedSelections(_ selections: [PromptModelSelection]) -> [PromptModelSelection] {
        var order: [String] = []
        var keyed: [String: PromptModelSelection] = [:]

        for selection in selections {
            if keyed[selection.id] == nil {
                order.append(selection.id)
            }
            keyed[selection.id] = selection
        }

        return order.compactMap { keyed[$0] }
    }

    func loadPromptModelSelections() {
        let raw = promptModelSelectionsData.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, let data = raw.data(using: .utf8) else {
            multiModelSelections = []
            return
        }

        if let decoded = try? JSONDecoder().decode([PromptModelSelection].self, from: data) {
            multiModelSelections = deduplicatedSelections(decoded)
        } else {
            multiModelSelections = []
        }
    }

    func persistPromptModelSelections() {
        let deduped = deduplicatedSelections(multiModelSelections)
        multiModelSelections = deduped
        guard let data = try? JSONEncoder().encode(deduped),
              let encoded = String(data: data, encoding: .utf8) else {
            promptModelSelectionsData = ""
            return
        }
        promptModelSelectionsData = encoded
    }

    func normalizePromptModelSelections(fallbackProviderId: String? = nil) {
        let normalized = normalizedSelections(
            multiModelSelections,
            fallbackProviderId: fallbackProviderId ?? selectedProviderId
        )
        guard normalized != multiModelSelections else { return }
        multiModelSelections = normalized
    }

    func normalizedSelections(
        _ selections: [PromptModelSelection],
        fallbackProviderId: String
    ) -> [PromptModelSelection] {
        let trimmedFallbackProviderId = fallbackProviderId.trimmingCharacters(in: .whitespacesAndNewlines)
        let knownProviderIds = Set(providers.map(\.id))

        return deduplicatedSelections(selections).map { selection in
            let trimmedProviderId = selection.providerId.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedProviderId: String
            if !trimmedProviderId.isEmpty, knownProviderIds.contains(trimmedProviderId) {
                resolvedProviderId = trimmedProviderId
            } else if !trimmedFallbackProviderId.isEmpty {
                resolvedProviderId = trimmedFallbackProviderId
            } else if providers.count == 1 {
                resolvedProviderId = providers[0].id
            } else {
                resolvedProviderId = trimmedProviderId
            }

            return PromptModelSelection(
                providerId: resolvedProviderId,
                modelId: selection.modelId,
                copyCount: selection.copyCount,
                reasoningEnabled: selection.reasoningEnabled,
                reasoningEffort: selection.reasoningEffort,
                serviceTier: resolvedServiceTier(selection.serviceTier, for: resolvedProviderId)
            )
        }
    }

    func restorePersistedServiceTierForSelectedProvider() {
        let restoredTier = persistedServiceTier(for: selectedProviderId)
        if serviceTier != restoredTier {
            serviceTier = restoredTier
        }
    }

    func persistServiceTier(_ tier: LLMServiceTier?, for providerId: String) {
        let trimmedProviderId = providerId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedProviderId.isEmpty else { return }

        var storedSelections = persistedServiceTierSelections()
        if let tier, isCodexProvider(id: trimmedProviderId) {
            storedSelections[trimmedProviderId] = tier.rawValue
        } else {
            storedSelections.removeValue(forKey: trimmedProviderId)
        }

        guard let data = try? JSONEncoder().encode(storedSelections),
              let encoded = String(data: data, encoding: .utf8) else {
            promptServiceTierSelectionsData = ""
            return
        }
        promptServiceTierSelectionsData = encoded
    }

    func persistedServiceTier(for providerId: String) -> LLMServiceTier? {
        guard isCodexProvider(id: providerId) else { return nil }
        guard let rawValue = persistedServiceTierSelections()[providerId] else { return nil }
        return LLMServiceTier(rawValue: rawValue)
    }

    func persistedServiceTierSelections() -> [String: String] {
        let raw = promptServiceTierSelectionsData.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, let data = raw.data(using: .utf8) else {
            return [:]
        }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    func resolvedServiceTier(_ currentTier: LLMServiceTier?, for providerId: String) -> LLMServiceTier? {
        guard isCodexProvider(id: providerId) else { return nil }
        return currentTier ?? persistedServiceTier(for: providerId)
    }

    func isCodexProvider(id: String) -> Bool {
        providers.first(where: { $0.id == id })?.backendMode == .codexOAuth
    }

    func syncContextAttachmentsIntoPromptBar() {
        let selectedSuggestions = contextProvider.attachedSuggestions
        let selectedIDs = Set(selectedSuggestions.map(\.id))

        let hadRemovals = attachments.contains { attachment in
            guard let suggestionID = attachment.origin.indexedSuggestionID else { return false }
            return !selectedIDs.contains(suggestionID)
        }

        if hadRemovals {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                attachments.removeAll { attachment in
                    guard let suggestionID = attachment.origin.indexedSuggestionID else { return false }
                    return !selectedIDs.contains(suggestionID)
                }
            }
        }

        for suggestion in selectedSuggestions {
            guard let url = contextAttachmentURL(for: suggestion) else { continue }
            let alreadyAttachedAsContext = attachments.contains {
                $0.origin.indexedSuggestionID == suggestion.id
            }
            if alreadyAttachedAsContext { continue }

            let alreadyAttachedByPath = attachments.contains { $0.url.path == url.path }
            if alreadyAttachedByPath { continue }

            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                attachments.append(
                    PromptAttachment(url: url, origin: .indexedContext(suggestionID: suggestion.id))
                )
            }
        }
    }

    func contextAttachmentURL(for suggestion: PromptContextSuggestion) -> URL? {
        guard suggestion.sourceType == "file" else { return nil }
        let path = suggestion.sourcePathOrHandle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }

    var isWorkerModelConfigured: Bool {
        guard let workerModelProviderId, let workerModelId else { return false }
        return !workerModelProviderId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !workerModelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var ghostContextSuggestions: [PromptContextSuggestion] {
        let selectedSuggestionIDs = Set(contextProvider.attachedSuggestions.map(\.id))
        let existingAttachmentPaths = Set(attachments.map { $0.url.path })
        return contextProvider.suggestions
            .filter { suggestion in
                guard !selectedSuggestionIDs.contains(suggestion.id) else { return false }
                guard let url = contextAttachmentURL(for: suggestion) else { return false }
                return !existingAttachmentPaths.contains(url.path)
            }
            .sorted { lhs, rhs in
                if lhs.relevanceScore == rhs.relevanceScore {
                    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }
                return lhs.relevanceScore > rhs.relevanceScore
            }
    }

    func donateGhostTipIfNeeded() {
        guard !hasDonatedGhostContextTip else { return }
        guard !ghostContextSuggestions.isEmpty else { return }
        hasDonatedGhostContextTip = true
        TipStore.shared.donateGhostContextSuggestionsShown()
    }
}
