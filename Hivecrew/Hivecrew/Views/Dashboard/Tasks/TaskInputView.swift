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
    @Query var providers: [LLMProviderRecord]
    
    @State private var taskDescription: String = ""
    @State var attachments: [PromptAttachment] = []
    @State private var isSubmitting: Bool = false
    @State private var mentionedSkillNames: [String] = []
    @State private var referencedTaskIds: [String] = []
    @State private var continuationSourceTaskId: String?
    @State var copyCount: TaskCopyCount = .one
    @State var multiModelSelections: [PromptModelSelection] = []
    @State var reasoningEnabled: Bool?
    @State var reasoningEffort: String?
    @State var serviceTier: LLMServiceTier?
    @StateObject var contextProvider = PromptContextSuggestionProvider()
    @StateObject private var mentionInsertionController = MentionInsertionController()
    @State var hasDonatedGhostContextTip = false
    
    // Persisted selections
    @AppStorage("lastSelectedProviderId") var selectedProviderId: String = ""
    @AppStorage("lastSelectedModelId") var selectedModelId: String = ""
    @AppStorage("useMultiplePromptModels") var useMultiplePromptModels: Bool = false
    @AppStorage("promptModelSelections") var promptModelSelectionsData: String = ""
    @AppStorage("promptServiceTierSelections") var promptServiceTierSelectionsData: String = ""
    @AppStorage("workerModelProviderId") var workerModelProviderId: String?
    @AppStorage("workerModelId") var workerModelId: String?
    
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
                referencedTaskIds: $referencedTaskIds,
                planFirstEnabled: $planFirstEnabled,
                onSubmit: {
                    await submitTask()
                },
                isSubmitting: $isSubmitting,
                mentionInsertionController: mentionInsertionController
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
        .onReceive(NotificationCenter.default.publisher(for: .continueFromTask)) { notification in
            guard let taskId = notification.userInfo?["taskId"] as? String,
                  let task = taskService.tasks.first(where: { $0.id == taskId }) else {
                return
            }

            continuationSourceTaskId = task.id
            let suggestion = MentionSuggestion(task: task)
            DispatchQueue.main.async {
                mentionInsertionController.focusTextView()
                mentionInsertionController.insertAtCurrentCursor(suggestion: suggestion)
            }
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
                        referencedTaskIds: referencedTaskIds,
                        continuationSourceTaskId: resolvedContinuationSourceTaskID,
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
            referencedTaskIds = []
            continuationSourceTaskId = nil
            if !useMultiplePromptModels {
                copyCount = .one  // Reset to single copy after submission
            }
            contextProvider.clearAfterSubmit()
        } catch {
            print("Failed to create task: \(error)")
        }
    }

    private var resolvedContinuationSourceTaskID: String? {
        guard let continuationSourceTaskId,
              referencedTaskIds.contains(continuationSourceTaskId) else {
            return nil
        }
        return continuationSourceTaskId
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
