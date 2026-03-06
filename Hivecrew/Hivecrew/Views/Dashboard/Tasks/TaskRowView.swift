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
    @State private var isHovered: Bool = false
    @State private var isRenaming: Bool = false
    @State private var draftTitle: String = ""
    @State private var showingTrace: Bool = false
    @State private var showingPlanReview: Bool = false
    @State private var showingRerunModelSelection: Bool = false
    @State private var showingMissingAttachments: Bool = false
    @State private var missingAttachmentsValidation: RerunAttachmentValidation?
    @State private var rerunTargetOverride: (providerId: String, modelId: String, reasoningEnabled: Bool?, reasoningEffort: String?)?
    @FocusState private var isTitleEditorFocused: Bool
    
    // Tips
    private let showDeliverableTip = ShowDeliverableTip()
    
    /// Whether the task is actively executing (not paused, waiting, or completed)
    var isActivelyRunning: Bool {
        effectiveStatus == .running
    }

    private var effectiveStatus: TaskStatus {
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
                            try? await taskService.rerunTask(
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
            
            // Rerun option for inactive tasks
            if !effectiveStatus.isActive {
                Button {
                    handleRerun()
                } label: {
                    Label("Rerun", systemImage: "arrow.counterclockwise")
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

    @ViewBuilder
    private var rowContainer: some View {
        if isRenaming {
            rowContent
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(rowBackground)
                .overlay(rowBorder)
        } else {
            Button(action: handleRowTap) {
                rowContent
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .overlay(rowBorder)
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color(nsColor: .controlBackgroundColor))
    }

    private var rowBorder: some View {
        RoundedRectangle(cornerRadius: 10)
            .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
    }

    private var rowContent: some View {
        HStack(spacing: 12) {
            // Status indicator
            if effectiveStatus == .planning {
                // Spinner for planning state
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 14, height: 14)
            } else if effectiveStatus == .planReview {
                // Blue clipboard icon for plan review
                Image(systemName: "list.bullet.clipboard.fill")
                    .foregroundStyle(.blue)
                    .font(.system(size: 14))
                    .frame(width: 14, height: 14)
            } else if let icon = completionIcon {
                // Show checkmark or X for completed tasks
                Image(systemName: icon)
                    .foregroundStyle(statusColor)
                    .font(.system(size: 14))
                    .frame(width: 14, height: 14)
            } else {
                // Status dot for active/other tasks
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                    .overlay(
                        Circle()
                            .stroke(statusColor.opacity(0.3), lineWidth: 2)
                    )
            }

            // Task info
            VStack(alignment: .leading, spacing: 2) {
                titleView

                // Status text
                HStack(spacing: 8) {
                    // Show verified status for completed tasks
                    if effectiveStatus == .completed, let success = task.wasSuccessful {
                        Text(success ? String(localized: "Verified Complete") : String(localized: "Incomplete"))
                            .font(.caption)
                            .foregroundStyle(success ? .green : .red)
                    } else {
                        Text(effectiveStatus.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // Show duration for completed tasks
                    if !effectiveStatus.isActive, task.completedAt != nil {
                        Text("•")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text(task.durationString)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    // Show elapsed time for running tasks
                    if effectiveStatus == .running, let startedAt = task.startedAt {
                        Text("•")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        ElapsedTimeView(startDate: startedAt)
                    }

                    // Show deliverable count for completed tasks with outputs
                    if !effectiveStatus.isActive, let outputPaths = task.outputFilePaths, !outputPaths.isEmpty {
                        Text("•")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Button(action: { showDeliverablesInFinder() }) {
                            HStack(spacing: 3) {
                                Image(systemName: "doc.fill")
                                    .font(.caption2)
                                Text("\(outputPaths.count)")
                                    .font(.caption)
                            }
                            .foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
                        .help("Show deliverables in Finder")
                        .popoverTip(showDeliverableTip, arrowEdge: .bottom)
                    }
                }
            }

            Spacer()

            // Actions (shown on hover or always for planReview)
            if !isRenaming && (isHovered || effectiveStatus == .planReview) {
                HStack(spacing: 8) {
                    // Plan Review actions
                    if effectiveStatus == .planReview {
                        Button {
                            showingPlanReview = true
                        } label: {
                            Text("Review")
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .controlSize(.small)
                        .help("Review and edit the execution plan")

                        Button {
                            Task { await taskService.executePlan(for: task) }
                        } label: {
                            Image(systemName: "play.fill")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .tint(.green)
                        .controlSize(.small)
                        .help("Execute the plan now")

                        Button {
                            Task { await taskService.cancelPlanning(for: task) }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .controlSize(.small)
                        .help("Cancel task")
                    } else {
                        // Rerun button for inactive tasks
                        if !effectiveStatus.isActive {
                            Button(action: { handleRerun() }) {
                                Image(systemName: "arrow.counterclockwise")
                                    .foregroundStyle(.blue)
                            }
                            .buttonStyle(.plain)
                            .help("Rerun task")
                        }

                        // Cancel button for planning state
                        if effectiveStatus == .planning {
                            Button(action: { Task { await taskService.cancelPlanning(for: task) } }) {
                                Image(systemName: "xmark.circle")
                                    .foregroundStyle(.orange)
                            }
                            .buttonStyle(.plain)
                            .help("Cancel planning")
                        } else if effectiveStatus.isActive {
                            Button(action: { Task { await taskService.cancelTask(task) } }) {
                                Image(systemName: "xmark.circle")
                                    .foregroundStyle(.orange)
                            }
                            .buttonStyle(.plain)
                            .help("Cancel task")
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var titleView: some View {
        if isRenaming {
            TextField("", text: $draftTitle)
                .textFieldStyle(.roundedBorder)
                .font(.body)
                .fontWeight(.medium)
                .focused($isTitleEditorFocused)
                .onSubmit {
                    submitRename()
                }
                .onAppear {
                    if draftTitle.isEmpty {
                        draftTitle = task.title
                    }
                    DispatchQueue.main.async {
                        isTitleEditorFocused = true
                    }
                }
        } else {
            Text(task.title)
                .font(.body)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }
    
    private func handleRowTap() {
        if effectiveStatus == .planning || effectiveStatus == .planReview {
            // Show plan review window (streaming during planning, editable during review)
            showingPlanReview = true
        } else if isActivelyRunning {
            // Navigate to task's environment if task is actively running
            navigateToTask(task.id)
        } else {
            // Show trace for non-running tasks
            showingTrace = true
        }
    }
    
    private func navigateToTask(_ taskId: String) {
        // Navigate to the task in the Environments tab
        NotificationCenter.default.post(
            name: .navigateToTask,
            object: nil,
            userInfo: ["taskId": taskId]
        )
    }

    private func beginRenaming() {
        draftTitle = task.title
        isRenaming = true
    }

    private func submitRename() {
        guard isRenaming else { return }

        let trimmedTitle = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            taskService.renameTask(task, to: trimmedTitle)
            draftTitle = trimmedTitle
        } else {
            draftTitle = task.title
        }

        isRenaming = false
        isTitleEditorFocused = false
    }
    
    /// Handle rerun button tap - checks for missing attachments first
    private func handleRerun(
        providerId: String? = nil,
        modelId: String? = nil,
        reasoningEnabled: Bool? = nil,
        reasoningEffort: String? = nil
    ) {
        let targetProviderId = providerId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? task.providerId
        let targetModelId = modelId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? task.modelId
        rerunTargetOverride = (
            providerId: targetProviderId.isEmpty ? task.providerId : targetProviderId,
            modelId: targetModelId.isEmpty ? task.modelId : targetModelId,
            reasoningEnabled: reasoningEnabled,
            reasoningEffort: reasoningEffort
        )
        
        // Validate attachments before rerunning
        let validation = taskService.validateRerunAttachments(task)
        
        if validation.allValid {
            // All attachments are valid, proceed with rerun
            Task {
                let rerunTarget = rerunTargetOverride ?? (
                    providerId: task.providerId,
                    modelId: task.modelId,
                    reasoningEnabled: task.reasoningEnabled,
                    reasoningEffort: task.reasoningEffort
                )
                defer { rerunTargetOverride = nil }
                try? await taskService.rerunTask(
                    task,
                    providerId: rerunTarget.providerId,
                    modelId: rerunTarget.modelId,
                    reasoningEnabled: rerunTarget.reasoningEnabled,
                    reasoningEffort: rerunTarget.reasoningEffort
                )
            }
        } else if validation.hasAttachments {
            // Some attachments are missing, show the sheet
            missingAttachmentsValidation = validation
            showingMissingAttachments = true
        } else {
            // No attachments at all, proceed with rerun
            Task {
                let rerunTarget = rerunTargetOverride ?? (
                    providerId: task.providerId,
                    modelId: task.modelId,
                    reasoningEnabled: task.reasoningEnabled,
                    reasoningEffort: task.reasoningEffort
                )
                defer { rerunTargetOverride = nil }
                try? await taskService.rerunTask(
                    task,
                    providerId: rerunTarget.providerId,
                    modelId: rerunTarget.modelId,
                    reasoningEnabled: rerunTarget.reasoningEnabled,
                    reasoningEffort: rerunTarget.reasoningEffort
                )
            }
        }
    }
    
    private func showDeliverablesInFinder() {
        guard let outputPaths = task.outputFilePaths, !outputPaths.isEmpty else { return }
        
        // Convert paths to URLs
        let urls = outputPaths.compactMap { URL(fileURLWithPath: $0) }
        
        // Filter to only existing files
        let existingURLs = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        
        if existingURLs.isEmpty {
            // If no files exist, try to open the output directory instead
            let outputDirectoryPath = UserDefaults.standard.string(forKey: "outputDirectoryPath") ?? ""
            let outputDirectory: URL
            if outputDirectoryPath.isEmpty {
                outputDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
            } else {
                outputDirectory = URL(fileURLWithPath: outputDirectoryPath)
            }
            NSWorkspace.shared.open(outputDirectory)
        } else {
            // Select the files in Finder
            NSWorkspace.shared.activateFileViewerSelecting(existingURLs)
        }
    }
}

// Notification for navigation
extension Notification.Name {
    static let navigateToTask = Notification.Name("navigateToTask")
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
