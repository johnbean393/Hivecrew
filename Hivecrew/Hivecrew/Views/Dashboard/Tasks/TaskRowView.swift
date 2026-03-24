//
//  TaskRowView.swift
//  Hivecrew
//
//  Individual task row with status indicator
//

import SwiftUI
import TipKit
import Combine

/// Individual task row with status dot and title
struct TaskRowView: View {
    let task: TaskRecord
    @EnvironmentObject var taskService: TaskService
    @State var isHovered: Bool = false
    @State var isRenaming: Bool = false
    @State var draftTitle: String = ""
    @State var showingTrace: Bool = false
    @State var showingPlanReview: Bool = false
    @State var showingWritebackReview: Bool = false
    @State var showingRerunModelSelection: Bool = false
    @State var showingMissingAttachments: Bool = false
    @State var missingAttachmentsValidation: RerunAttachmentValidation?
    @State var rerunTargetOverride: (providerId: String, modelId: String, reasoningEnabled: Bool?, reasoningEffort: String?)?
    @FocusState var isTitleEditorFocused: Bool
    
    // Tips
    let showDeliverableTip = ShowDeliverableTip()
    
    /// Whether the task is actively executing (not paused, waiting, or completed)
    var isActivelyRunning: Bool {
        effectiveStatus == .running
    }

    var effectiveStatus: TaskStatus {
        taskService.effectiveStatus(for: task)
    }
    
    var statusColor: Color {
        switch effectiveStatus {
            case .queued, .waitingForVM, .paused, .planning:
                return .yellow
            case .running:
                return .green
            case .completed:
                // Use wasSuccessful to determine color if available
                if let success = task.wasSuccessful {
                    return success ? .green : .red
                }
                return .gray
            case .failed, .planFailed:
                return .red
            case .cancelled:
                return .gray
            case .timedOut, .maxIterations:
                return .orange
            case .planReview:
                return .blue
            case .writebackReview:
                return .blue
        }
    }
    
    /// Icon for completed task based on wasSuccessful
    var completionIcon: String? {
        guard effectiveStatus == .completed else { return nil }
        if let success = task.wasSuccessful {
            return success ? "checkmark.circle.fill" : "xmark.circle.fill"
        }
        return nil
    }
    
    var body: some View {
        rowContainer
        .onHover { hovering in
            isHovered = hovering
        }
        .onChange(of: isTitleEditorFocused) { _, isFocused in
            if !isFocused {
                submitRename()
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            // Only show delete action for non-active tasks
            if !effectiveStatus.isActive {
                Button(role: .destructive) {
                    Task { await taskService.deleteTask(task) }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .sheet(isPresented: $showingTrace) {
            SessionTraceView(task: task)
        }
        .sheet(isPresented: $showingPlanReview) {
            PlanReviewWindow(task: task, taskService: taskService)
        }
        .sheet(isPresented: $showingWritebackReview) {
            WritebackReviewWindow(task: task, taskService: taskService)
        }
        .sheet(isPresented: $showingMissingAttachments) {
            if let validation = missingAttachmentsValidation {
                MissingAttachmentsSheet(
                    task: task,
                    missingAttachments: validation.missingInfos,
                    validAttachments: validation.validInfos,
                    onConfirm: { resolvedAttachments in
                        showingMissingAttachments = false
                        Task {
                            let rerunTarget = rerunTargetOverride ?? (
                                providerId: task.providerId,
                                modelId: task.modelId,
                                reasoningEnabled: task.reasoningEnabled,
                                reasoningEffort: task.reasoningEffort
                            )
                            defer { rerunTargetOverride = nil }
                            let _ = try? await taskService.rerunTask(
                                task,
                                providerId: rerunTarget.providerId,
                                modelId: rerunTarget.modelId,
                                reasoningEnabled: rerunTarget.reasoningEnabled,
                                reasoningEffort: rerunTarget.reasoningEffort,
                                withResolvedAttachments: resolvedAttachments
                            )
                        }
                    },
                    onCancel: {
                        showingMissingAttachments = false
                        rerunTargetOverride = nil
                    }
                )
            }
        }
        .sheet(isPresented: $showingRerunModelSelection) {
            RerunModelSelectionSheet(task: task) { providerId, modelId, reasoningEnabled, reasoningEffort in
                handleRerun(
                    providerId: providerId,
                    modelId: modelId,
                    reasoningEnabled: reasoningEnabled,
                    reasoningEffort: reasoningEffort
                )
            }
        }
        .contextMenu {
            // View trace option
            Button {
                showingTrace = true
            } label: {
                Label("View Trace", systemImage: "list.bullet.rectangle")
            }

            Button {
                beginRenaming()
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            if effectiveStatus == .writebackReview {
                Button {
                    showingWritebackReview = true
                } label: {
                    Label("Review Changes", systemImage: "square.and.arrow.down")
                }
            }
            
            // Rerun option for inactive tasks
            if !effectiveStatus.isActive {
                Button {
                    handleRerun()
                } label: {
                    Label("Rerun", systemImage: "arrow.counterclockwise")
                }

                Button {
                    continueFromTask()
                } label: {
                    Label("Continue from Task", systemImage: "arrow.turn.down.right")
                }
                
                Button {
                    showingRerunModelSelection = true
                } label: {
                    Label("Rerun with Different Model...", systemImage: "brain")
                }
            }
            
            // Show deliverables
            if let outputPaths = task.outputFilePaths, !outputPaths.isEmpty {
                Button {
                    showDeliverablesInFinder()
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
            }
            
            // Cancel option for active tasks
            if effectiveStatus.isActive {
                Divider()
                Button(role: .destructive) {
                    Task { await taskService.cancelTask(task) }
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                }
            }
            
            // Delete option for inactive tasks
            if !effectiveStatus.isActive {
                Divider()
                Button(role: .destructive) {
                    Task { await taskService.deleteTask(task) }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

}

// Notification for navigation
extension Notification.Name {
    static let navigateToTask = Notification.Name("navigateToTask")
    static let continueFromTask = Notification.Name("continueFromTask")
}

#Preview {
    VStack(spacing: 8) {
        TaskRowView(task: TaskRecord(
            title: "Create Paris Trip Research `docx`",
            taskDescription: "Research places to visit in Paris",
            status: .waitingForVM,
            providerId: "test",
            modelId: "moonshotai/kimi-k2.5"
        ))
        
        TaskRowView(task: TaskRecord(
            title: "Create Paris Trip Research `docx`",
            taskDescription: "Research places to visit in Paris",
            status: .running,
            startedAt: Date().addingTimeInterval(-125),
            providerId: "test",
            modelId: "moonshotai/kimi-k2.5"
        ))
        
        TaskRowView(task: TaskRecord(
            title: "Invent Nuclear Fusion",
            taskDescription: "Solve cold fusion",
            status: .failed,
            completedAt: Date(),
            providerId: "test",
            modelId: "moonshotai/kimi-k2.5",
            errorMessage: "Task is impossible"
        ))
    }
    .environmentObject(TaskService())
    .padding()
    .frame(width: 500)
}
