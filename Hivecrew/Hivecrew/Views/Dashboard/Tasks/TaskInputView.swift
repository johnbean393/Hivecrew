//
//  TaskInputView.swift
//  Hivecrew
//
//  Chat-style task input with attachment and model selection
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import HivecrewLLM

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
    
    // Persisted selections
    @AppStorage("lastSelectedProviderId") private var selectedProviderId: String = ""
    @AppStorage("lastSelectedModelId") private var selectedModelId: String = ""
    
    var body: some View {
        PromptBar(
            text: $taskDescription,
            attachments: $attachments,
            selectedProviderId: $selectedProviderId,
            selectedModelId: $selectedModelId,
            copyCount: $copyCount,
            mentionedSkillNames: $mentionedSkillNames,
            onSubmit: {
                await submitTask()
            },
            isSubmitting: $isSubmitting
        )
        .padding(.horizontal, 40)
        .onAppear {
            // Select default provider only if no provider is currently selected
            // or if the stored provider no longer exists
            let storedProviderExists = providers.contains { $0.id == selectedProviderId }
            if selectedProviderId.isEmpty || !storedProviderExists,
               let defaultProvider = providers.first(where: { $0.isDefault }) ?? providers.first {
                selectedProviderId = defaultProvider.id
            }
        }
        .onChange(of: providers) { oldValue, newValue in
            // Update if no provider selected or stored provider was deleted
            let storedProviderExists = newValue.contains { $0.id == selectedProviderId }
            if selectedProviderId.isEmpty || !storedProviderExists,
               let first = newValue.first(where: { $0.isDefault }) ?? newValue.first {
                selectedProviderId = first.id
            }
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
        
        let effectiveModelId = currentModelId.isEmpty ? "gpt-5.2" : currentModelId
        let effectiveProviderId = currentProviderId.isEmpty ? selectedProviderId : currentProviderId
        
        let taskCount = copyCount.rawValue
        print("TaskInputView: Submitting \(taskCount) task(s) with provider=\(effectiveProviderId), model=\(effectiveModelId)")
        
        do {
            let filePaths = attachments.map { $0.url.path }
            let trimmedDescription = taskDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Create the specified number of task copies
            for _ in 0..<taskCount {
                _ = try await taskService.createTask(
                    description: trimmedDescription,
                    providerId: effectiveProviderId,
                    modelId: effectiveModelId,
                    attachedFilePaths: filePaths,
                    mentionedSkillNames: mentionedSkillNames
                )
            }
            
            // Clear input
            taskDescription = ""
            attachments = []
            mentionedSkillNames = []
            copyCount = .one  // Reset to single copy after submission
        } catch {
            print("Failed to create task: \(error)")
        }
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
