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
    @StateObject private var contextProvider = PromptContextSuggestionProvider()
    
    // Persisted selections
    @AppStorage("lastSelectedProviderId") private var selectedProviderId: String = ""
    @AppStorage("lastSelectedModelId") private var selectedModelId: String = ""
    
    // Non-persisted - always defaults to Direct mode on launch
    @State private var planFirstEnabled: Bool = false
    
    var body: some View {
        VStack(spacing: 8) {
            PromptBar(
                text: $taskDescription,
                attachments: $attachments,
                onRemoveAttachment: { removed in
                    if let suggestionID = removed.origin.indexedSuggestionID {
                        contextProvider.detachSuggestion(withID: suggestionID)
                    }
                },
                selectedProviderId: $selectedProviderId,
                selectedModelId: $selectedModelId,
                copyCount: $copyCount,
                mentionedSkillNames: $mentionedSkillNames,
                planFirstEnabled: $planFirstEnabled,
                onSubmit: {
                    await submitTask()
                },
                isSubmitting: $isSubmitting
            )
            .padding(.horizontal, 40)

            ContextSuggestionDrawer(provider: contextProvider)
                .padding(.horizontal, 40)
        }
        .onAppear {
            // Select default provider only if no provider is currently selected
            // or if the stored provider no longer exists.
            let storedProviderExists = providers.contains { $0.id == selectedProviderId }
            if selectedProviderId.isEmpty || !storedProviderExists,
               let defaultProvider = providers.first(where: { $0.isDefault }) ?? providers.first {
                selectedProviderId = defaultProvider.id
            }
            contextProvider.updateDraft(taskDescription)
        }
        .onChange(of: providers) { _, newValue in
            // Update if no provider selected or stored provider was deleted.
            let storedProviderExists = newValue.contains { $0.id == selectedProviderId }
            if selectedProviderId.isEmpty || !storedProviderExists,
               let first = newValue.first(where: { $0.isDefault }) ?? newValue.first {
                selectedProviderId = first.id
            }
        }
        .onChange(of: taskDescription) { _, newValue in
            contextProvider.updateDraft(newValue)
        }
        .onChange(of: contextProvider.attachedSuggestions) { _, _ in
            syncContextAttachmentsIntoPromptBar()
        }
    }
    
    private func submitTask() async {
        guard !taskDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !selectedProviderId.isEmpty else { return }
        
        isSubmitting = true
        defer { isSubmitting = false }
        
        // Read directly from UserDefaults to ensure we have the latest value
        let currentModelId = UserDefaults.standard.string(forKey: "lastSelectedModelId") ?? selectedModelId
        let currentProviderId = UserDefaults.standard.string(forKey: "lastSelectedProviderId") ?? selectedProviderId
        
        let effectiveModelId = currentModelId.isEmpty ? "moonshotai/kimi-k2.5" : currentModelId
        let effectiveProviderId = currentProviderId.isEmpty ? selectedProviderId : currentProviderId
        
        let taskCount = copyCount.rawValue
        print("TaskInputView: Submitting \(taskCount) task(s) with provider=\(effectiveProviderId), model=\(effectiveModelId)")
        
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
            
            // Create the specified number of task copies
            for _ in 0..<taskCount {
                _ = try await taskService.createTask(
                    description: trimmedDescription,
                    providerId: effectiveProviderId,
                    modelId: effectiveModelId,
                    attachedFilePaths: filePaths,
                    mentionedSkillNames: mentionedSkillNames,
                    retrievalContextPackId: contextPack?.id,
                    retrievalInlineContextBlocks: inlineContext,
                    retrievalContextAttachmentPaths: contextAttachmentPaths,
                    retrievalSelectedSuggestionIds: selectedSuggestionIds,
                    retrievalModeOverrides: modeOverrides,
                    planFirstEnabled: planFirstEnabled
                )
            }
            
            // Track task creation for tips
            TipStore.shared.donateTaskCreated()
            TipStore.shared.firstTaskCreated()
            
            // Clear input
            taskDescription = ""
            attachments = []
            mentionedSkillNames = []
            copyCount = .one  // Reset to single copy after submission
            contextProvider.clearAfterSubmit()
        } catch {
            print("Failed to create task: \(error)")
        }
    }

    private func syncContextAttachmentsIntoPromptBar() {
        let selectedSuggestions = contextProvider.attachedSuggestions
        let selectedIDs = Set(selectedSuggestions.map(\.id))

        // Remove attachment chips for suggestions that are no longer selected.
        attachments.removeAll { attachment in
            guard let suggestionID = attachment.origin.indexedSuggestionID else { return false }
            return !selectedIDs.contains(suggestionID)
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

            attachments.append(
                PromptAttachment(
                    url: url,
                    origin: .indexedContext(suggestionID: suggestion.id)
                )
            )
        }
    }

    private func contextAttachmentURL(for suggestion: PromptContextSuggestion) -> URL? {
        guard suggestion.sourceType == "file" else { return nil }
        let path = suggestion.sourcePathOrHandle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
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
