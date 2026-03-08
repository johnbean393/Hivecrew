//
//  TaskInputView.swift
//  Hivecrew
//
//  Chat-style task input with attachment and model selection
//

import Combine
import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import HivecrewLLM
import HivecrewShared

/// Chat-style input for creating new tasks
struct TaskInputView: View {
    @EnvironmentObject var taskService: TaskService
    @Environment(\.modelContext) private var modelContext
    @Query private var providers: [LLMProviderRecord]
    
    @State private var taskDescription: String = ""
    @State private var attachments: [PromptAttachment] = []
    @State private var isSubmitting: Bool = false
    @State private var mentionedSkillNames: [String] = []
    @State private var copyCount: TaskCopyCount = .one
    @State private var multiModelSelections: [PromptModelSelection] = []
    @State private var reasoningEnabled: Bool?
    @State private var reasoningEffort: String?
    @State private var serviceTier: LLMServiceTier?
    @StateObject private var contextProvider = PromptContextSuggestionProvider()
    @State private var hasDonatedGhostContextTip = false
    
    // Persisted selections
    @AppStorage("lastSelectedProviderId") private var selectedProviderId: String = ""
    @AppStorage("lastSelectedModelId") private var selectedModelId: String = ""
    @AppStorage("useMultiplePromptModels") private var useMultiplePromptModels: Bool = false
    @AppStorage("promptModelSelections") private var promptModelSelectionsData: String = ""
    @AppStorage("promptServiceTierSelections") private var promptServiceTierSelectionsData: String = ""
    @AppStorage("workerModelProviderId") private var workerModelProviderId: String?
    @AppStorage("workerModelId") private var workerModelId: String?
    
    // Non-persisted - always defaults to Direct mode on launch
    @State private var planFirstEnabled: Bool = false
    
    var body: some View {
        VStack(spacing: 8) {
            PromptBar(
                text: $taskDescription,
                attachments: $attachments,
                ghostSuggestions: ghostContextSuggestions,
                onRemoveAttachment: { removed in
                    if let suggestionID = removed.origin.indexedSuggestionID {
                        contextProvider.detachSuggestion(withID: suggestionID)
                    }
                },
                onPromoteGhostSuggestion: { suggestion in
                    contextProvider.attachSuggestion(suggestion)
                },
                selectedProviderId: $selectedProviderId,
                selectedModelId: $selectedModelId,
                reasoningEnabled: $reasoningEnabled,
                reasoningEffort: $reasoningEffort,
                serviceTier: $serviceTier,
                copyCount: $copyCount,
                useMultipleModels: $useMultiplePromptModels,
                multiModelSelections: $multiModelSelections,
                mentionedSkillNames: $mentionedSkillNames,
                planFirstEnabled: $planFirstEnabled,
                onSubmit: {
                    await submitTask()
                },
                isSubmitting: $isSubmitting
            )
            .padding(.horizontal, 40)

            if !isWorkerModelConfigured {
                Text("Worker model is required before sending tasks. Configure it in onboarding or Settings → Providers.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 40)
            }

        }
        .onAppear {
            // Select default provider only if no provider is currently selected
            // or if the stored provider no longer exists.
            let storedProviderExists = providers.contains { $0.id == selectedProviderId }
            if selectedProviderId.isEmpty || !storedProviderExists,
               let defaultProvider = providers.first(where: { $0.isDefault }) ?? providers.first {
                selectedProviderId = defaultProvider.id
            }
            contextProvider.setWorkerClientProvider(taskService)
            contextProvider.updateDraft(taskDescription)
            loadPromptModelSelections()
            normalizePromptModelSelections()
            restorePersistedServiceTierForSelectedProvider()
        }
        .onChange(of: providers) { _, newValue in
            // Update if no provider selected or stored provider was deleted.
            let storedProviderExists = newValue.contains { $0.id == selectedProviderId }
            if selectedProviderId.isEmpty || !storedProviderExists,
               let first = newValue.first(where: { $0.isDefault }) ?? newValue.first {
                selectedProviderId = first.id
            }
            normalizePromptModelSelections()
            restorePersistedServiceTierForSelectedProvider()
        }
        .onChange(of: taskDescription) { _, newValue in
            contextProvider.updateDraft(newValue)
        }
        .onChange(of: contextProvider.attachedSuggestions) { _, _ in
            syncContextAttachmentsIntoPromptBar()
        }
        .onChange(of: contextProvider.suggestions) { _, _ in
            donateGhostTipIfNeeded()
        }
        .onChange(of: attachments) { _, _ in
            donateGhostTipIfNeeded()
        }
        .onChange(of: multiModelSelections) { _, _ in
            persistPromptModelSelections()
        }
        .onChange(of: selectedProviderId) { _, _ in
            normalizePromptModelSelections()
            restorePersistedServiceTierForSelectedProvider()
        }
        .onChange(of: serviceTier) { _, newValue in
            persistServiceTier(newValue, for: selectedProviderId)
        }
    }
    
    private func submitTask() async {
        guard !taskDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if useMultiplePromptModels {
            guard !multiModelSelections.isEmpty else { return }
        } else {
            guard !selectedProviderId.isEmpty else { return }
        }
        guard isWorkerModelConfigured else { return }
        
        isSubmitting = true
        defer { isSubmitting = false }
        
        // Read directly from UserDefaults to ensure we have the latest value
        let currentModelId = UserDefaults.standard.string(forKey: "lastSelectedModelId") ?? selectedModelId
        let currentProviderId = UserDefaults.standard.string(forKey: "lastSelectedProviderId") ?? selectedProviderId
        
        let effectiveModelId = currentModelId.isEmpty ? "moonshotai/kimi-k2.5" : currentModelId
        let effectiveProviderId = currentProviderId.isEmpty ? selectedProviderId : currentProviderId

        normalizePromptModelSelections(fallbackProviderId: effectiveProviderId)
        
        let executionTargets = resolvedExecutionTargets(
            effectiveProviderId: effectiveProviderId,
            effectiveModelId: effectiveModelId
        )
        let taskCount = executionTargets.reduce(0) { partial, target in
            partial + target.copyCount
        }
        print("TaskInputView: Submitting \(taskCount) task(s) across \(executionTargets.count) target(s)")
        
        do {
            let trimmedDescription = taskDescription.trimmingCharacters(in: .whitespacesAndNewlines)

            let contextPack: RetrievalContextPackPayload?
            do {
                contextPack = try await contextProvider.createContextPackIfNeeded(query: trimmedDescription)
            } catch {
                // Retrieval context is additive only; task creation still proceeds.
                print("TaskInputView: Context pack creation failed, continuing without it: \(error)")
                contextPack = nil
            }
            let fallbackContextAttachmentPaths = contextProvider.selectedFileAttachmentPathsForFallback()
            let contextAttachmentPaths = contextPack?.attachmentPaths ?? fallbackContextAttachmentPaths
            let userAttachmentPaths = attachments
                .filter { $0.origin.indexedSuggestionID == nil }
                .map { $0.url.path }
            let filePaths = Array(
                Set(userAttachmentPaths + contextAttachmentPaths)
            ).sorted()
            let inlineContext = contextPack?.inlinePromptBlocks ?? []
            let selectedSuggestionIds = contextProvider.selectedSuggestionIDs()
            let modeOverrides = contextProvider.selectedModeOverrides()

            let taskRequests = executionTargets.flatMap { target in
                Array(
                    repeating: TaskCreationRequest(
                        description: trimmedDescription,
                        providerId: target.providerId,
                        modelId: target.modelId,
                        reasoningEnabled: target.reasoningEnabled,
                        reasoningEffort: target.reasoningEffort,
                        serviceTier: target.serviceTier,
                        attachedFilePaths: filePaths,
                        attachmentInfos: nil,
                        outputDirectory: nil,
                        mentionedSkillNames: mentionedSkillNames,
                        retrievalContextPackId: contextPack?.id,
                        retrievalInlineContextBlocks: inlineContext,
                        retrievalContextAttachmentPaths: contextAttachmentPaths,
                        retrievalSelectedSuggestionIds: selectedSuggestionIds,
                        retrievalModeOverrides: modeOverrides,
                        planFirstEnabled: planFirstEnabled,
                        planMarkdown: nil,
                        planSelectedSkillNames: nil
                    ),
                    count: target.copyCount
                )
            }

            _ = try await taskService.createTasks(taskRequests)
            
            // Track task creation for tips
            TipStore.shared.donateTaskCreated()
            TipStore.shared.firstTaskCreated()
            
            // Clear input
            taskDescription = ""
            attachments = []
            mentionedSkillNames = []
            if !useMultiplePromptModels {
                copyCount = .one  // Reset to single copy after submission
            }
            contextProvider.clearAfterSubmit()
        } catch {
            print("Failed to create task: \(error)")
        }
    }

    private func resolvedExecutionTargets(
        effectiveProviderId: String,
        effectiveModelId: String
    ) -> [(providerId: String, modelId: String, copyCount: Int, reasoningEnabled: Bool?, reasoningEffort: String?, serviceTier: LLMServiceTier?)] {
        if useMultiplePromptModels {
            let deduped = normalizedSelections(
                deduplicatedSelections(multiModelSelections),
                fallbackProviderId: effectiveProviderId
            )
            let targets = deduped
                .filter { !$0.providerId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .filter { !$0.modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
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

    private func deduplicatedSelections(_ selections: [PromptModelSelection]) -> [PromptModelSelection] {
        var order: [String] = []
        var keyed: [String: PromptModelSelection] = [:]

        for selection in selections {
            if keyed[selection.id] == nil {
                order.append(selection.id)
                keyed[selection.id] = selection
            } else {
                keyed[selection.id] = selection
            }
        }

        return order.compactMap { keyed[$0] }
    }

    private func loadPromptModelSelections() {
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

    private func persistPromptModelSelections() {
        let deduped = deduplicatedSelections(multiModelSelections)
        multiModelSelections = deduped
        guard let data = try? JSONEncoder().encode(deduped),
              let encoded = String(data: data, encoding: .utf8) else {
            promptModelSelectionsData = ""
            return
        }
        promptModelSelectionsData = encoded
    }

    private func normalizePromptModelSelections(fallbackProviderId: String? = nil) {
        let normalized = normalizedSelections(
            multiModelSelections,
            fallbackProviderId: fallbackProviderId ?? selectedProviderId
        )
        guard normalized != multiModelSelections else { return }
        multiModelSelections = normalized
    }

    private func normalizedSelections(
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
                serviceTier: resolvedServiceTier(
                    selection.serviceTier,
                    for: resolvedProviderId
                )
            )
        }
    }

    private func restorePersistedServiceTierForSelectedProvider() {
        let restoredTier = persistedServiceTier(for: selectedProviderId)
        if serviceTier != restoredTier {
            serviceTier = restoredTier
        }
    }

    private func persistServiceTier(_ tier: LLMServiceTier?, for providerId: String) {
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

    private func persistedServiceTier(for providerId: String) -> LLMServiceTier? {
        guard isCodexProvider(id: providerId) else { return nil }
        guard let rawValue = persistedServiceTierSelections()[providerId] else { return nil }
        return LLMServiceTier(rawValue: rawValue)
    }

    private func persistedServiceTierSelections() -> [String: String] {
        let raw = promptServiceTierSelectionsData.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, let data = raw.data(using: .utf8) else {
            return [:]
        }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private func resolvedServiceTier(_ currentTier: LLMServiceTier?, for providerId: String) -> LLMServiceTier? {
        guard isCodexProvider(id: providerId) else { return nil }
        return currentTier ?? persistedServiceTier(for: providerId)
    }

    private func isCodexProvider(id: String) -> Bool {
        providers.first(where: { $0.id == id })?.backendMode == .codexOAuth
    }

    private func syncContextAttachmentsIntoPromptBar() {
        let selectedSuggestions = contextProvider.attachedSuggestions
        let selectedIDs = Set(selectedSuggestions.map(\.id))

        // Remove attachment chips for suggestions that are no longer selected.
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

            // Avoid duplicate visual chips for the same file if user already attached it manually.
            let alreadyAttachedByPath = attachments.contains { $0.url.path == url.path }
            if alreadyAttachedByPath { continue }

            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                attachments.append(
                    PromptAttachment(
                        url: url,
                        origin: .indexedContext(suggestionID: suggestion.id)
                    )
                )
            }
        }
    }

    private func contextAttachmentURL(for suggestion: PromptContextSuggestion) -> URL? {
        guard suggestion.sourceType == "file" else { return nil }
        let path = suggestion.sourcePathOrHandle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }

    private var isWorkerModelConfigured: Bool {
        guard let workerModelProviderId,
              let workerModelId else { return false }
        return !workerModelProviderId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !workerModelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var ghostContextSuggestions: [PromptContextSuggestion] {
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

    private func donateGhostTipIfNeeded() {
        guard !hasDonatedGhostContextTip else { return }
        guard !ghostContextSuggestions.isEmpty else { return }
        hasDonatedGhostContextTip = true
        TipStore.shared.donateGhostContextSuggestionsShown()
    }
}

// MARK: - Preview

#Preview {
    TaskInputView()
        .environmentObject(TaskService())
        .environmentObject(SchedulerService.shared)
        .modelContainer(for: [LLMProviderRecord.self, TaskRecord.self, ScheduledTask.self], inMemory: true)
        .frame(width: 600)
        .padding()
}
