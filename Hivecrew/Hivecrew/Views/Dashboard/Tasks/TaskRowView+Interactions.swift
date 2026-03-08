import AppKit
import SwiftUI
import TipKit

extension TaskRowView {
    @ViewBuilder
    var rowContainer: some View {
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

    var rowBackground: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color(nsColor: .controlBackgroundColor))
    }

    var rowBorder: some View {
        RoundedRectangle(cornerRadius: 10)
            .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
    }

    var rowContent: some View {
        HStack(spacing: 12) {
            if effectiveStatus == .planning {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 14, height: 14)
            } else if effectiveStatus == .planReview {
                Image(systemName: "list.bullet.clipboard.fill")
                    .foregroundStyle(.blue)
                    .font(.system(size: 14))
                    .frame(width: 14, height: 14)
            } else if let icon = completionIcon {
                Image(systemName: icon)
                    .foregroundStyle(statusColor)
                    .font(.system(size: 14))
                    .frame(width: 14, height: 14)
            } else {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(statusColor.opacity(0.3), lineWidth: 2))
            }

            VStack(alignment: .leading, spacing: 2) {
                titleView

                HStack(spacing: 8) {
                    if effectiveStatus == .completed, let success = task.wasSuccessful {
                        Text(success ? String(localized: "Verified Complete") : String(localized: "Incomplete"))
                            .font(.caption)
                            .foregroundStyle(success ? .green : .red)
                    } else {
                        Text(effectiveStatus.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !effectiveStatus.isActive, task.completedAt != nil {
                        Text("•")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text(task.durationString)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    if effectiveStatus == .running, let startedAt = task.startedAt {
                        Text("•")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        ElapsedTimeView(startDate: startedAt)
                    }

                    if !effectiveStatus.isActive, let outputPaths = task.outputFilePaths, !outputPaths.isEmpty {
                        Text("•")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Button(action: showDeliverablesInFinder) {
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

            if !isRenaming && (isHovered || effectiveStatus == .planReview) {
                taskActions
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    var titleView: some View {
        if isRenaming {
            TextField("", text: $draftTitle)
                .textFieldStyle(.roundedBorder)
                .font(.body)
                .fontWeight(.medium)
                .focused($isTitleEditorFocused)
                .onSubmit(submitRename)
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

    @ViewBuilder
    var taskActions: some View {
        HStack(spacing: 8) {
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
                if !effectiveStatus.isActive {
                    Button(action: { handleRerun() }) {
                        Image(systemName: "arrow.counterclockwise")
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .help("Rerun task")

                    Button(action: continueFromTask) {
                        Image(systemName: "arrow.turn.down.right")
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .help("Continue from task")
                }

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

    func handleRowTap() {
        if effectiveStatus == .planning || effectiveStatus == .planReview {
            showingPlanReview = true
        } else if isActivelyRunning {
            navigateToTask(task.id)
        } else {
            showingTrace = true
        }
    }

    func navigateToTask(_ taskId: String) {
        NotificationCenter.default.post(
            name: .navigateToTask,
            object: nil,
            userInfo: ["taskId": taskId]
        )
    }

    func beginRenaming() {
        draftTitle = task.title
        isRenaming = true
    }

    func submitRename() {
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

    func handleRerun(
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

        let validation = taskService.validateRerunAttachments(task)
        if validation.allValid {
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
            missingAttachmentsValidation = validation
            showingMissingAttachments = true
        } else {
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

    func showDeliverablesInFinder() {
        guard let outputPaths = task.outputFilePaths, !outputPaths.isEmpty else { return }
        let urls = outputPaths.compactMap { URL(fileURLWithPath: $0) }
        let existingURLs = urls.filter { FileManager.default.fileExists(atPath: $0.path) }

        if existingURLs.isEmpty {
            let outputDirectoryPath = UserDefaults.standard.string(forKey: "outputDirectoryPath") ?? ""
            let outputDirectory: URL
            if outputDirectoryPath.isEmpty {
                outputDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                    ?? URL(fileURLWithPath: NSHomeDirectory())
            } else {
                outputDirectory = URL(fileURLWithPath: outputDirectoryPath)
            }
            NSWorkspace.shared.open(outputDirectory)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(existingURLs)
        }
    }

    func continueFromTask() {
        NotificationCenter.default.post(
            name: .continueFromTask,
            object: nil,
            userInfo: ["taskId": task.id]
        )
    }
}
