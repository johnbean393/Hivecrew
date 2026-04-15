//
//  TaskDetailView.swift
//  Hivelink
//

import HivecrewCore
import SwiftData
import SwiftUI

struct TaskDetailView: View {
    let taskId: String

    @EnvironmentObject private var taskService: HivelinkTaskService

    var body: some View {
        Group {
            if let task = taskService.getTask(byId: taskId) {
                taskContent(task)
            } else {
                ContentUnavailableView("Task not found", systemImage: "exclamationmark.triangle")
            }
        }
        .navigationTitle("Task")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func taskContent(_ task: TaskRecord) -> some View {
        switch task.status {
        case .running, .waitingForVM, .planning, .paused:
            RunningTaskDetailView(task: task)

        case .completed, .failed, .cancelled, .timedOut, .maxIterations, .planFailed:
            CompletedTaskDetailView(task: task)

        case .queued:
            queuedView(task)

        case .planReview:
            planReviewView(task)

        case .writebackReview:
            writebackReviewView(task)
        }
    }

    // MARK: - Queued

    private func queuedView(_ task: TaskRecord) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(task.title)
                    .font(.title3.weight(.semibold))
                Text(task.taskDescription)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            if !task.attachmentInfos.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Attachments")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    ForEach(task.attachmentInfos, id: \.effectivePath) { info in
                        HStack(spacing: 6) {
                            Image(systemName: "paperclip")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(URL(fileURLWithPath: info.effectivePath).lastPathComponent)
                                .font(.caption)
                                .lineLimit(1)
                        }
                    }
                }
            }

            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting in queue…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack {
                Spacer()
                Button(role: .destructive) {
                    Task { await taskService.cancelTask(task) }
                } label: {
                    Label("Cancel Task", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                Spacer()
            }
        }
        .padding(20)
    }

    // MARK: - Plan review

    private func planReviewView(_ task: TaskRecord) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Plan Review")
                .font(.title3.weight(.semibold))

            if let plan = task.planMarkdown, !plan.isEmpty {
                ScrollView {
                    Text(plan)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("No plan content available.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 12) {
                Button {
                    Task { await taskService.resumeTask(task) }
                } label: {
                    Label("Approve", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)

                Button(role: .destructive) {
                    Task { await taskService.cancelTask(task) }
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .tint(.orange)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(20)
    }

    // MARK: - Writeback review

    private func writebackReviewView(_ task: TaskRecord) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review Changes")
                .font(.title3.weight(.semibold))

            let count = task.pendingWritebackOperations.count
            Text("\(count) pending change\(count == 1 ? "" : "s") to apply")
                .font(.body)
                .foregroundStyle(.secondary)

            if !task.pendingWritebackOperations.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(task.pendingWritebackOperations) { op in
                            HStack(spacing: 8) {
                                Image(systemName: "doc.text")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(op.sourceFileName)
                                        .font(.caption.weight(.medium))
                                    Text(op.destinationPath)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }

            Spacer()

            HStack(spacing: 12) {
                Button {
                    Task { await taskService.resumeTask(task) }
                } label: {
                    Label("Approve", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)

                Button(role: .destructive) {
                    Task { await taskService.cancelTask(task) }
                } label: {
                    Label("Discard", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(20)
    }
}

#Preview {
    NavigationStack {
        TaskDetailView(taskId: "preview-1")
    }
    .environmentObject(HivelinkTaskService(
        modelContext: {
            let container = try! ModelContainer(for: TaskRecord.self)
            return ModelContext(container)
        }(),
        clusterCoordinator: HivelinkClusterCoordinator(),
        remoteTaskIndex: RemoteTaskIndex()
    ))
    .environmentObject(PeerConnectionManager(
        remoteTaskIndex: RemoteTaskIndex(),
        clusterCoordinator: HivelinkClusterCoordinator()
    ))
    .environmentObject(ArtifactImportCoordinator())
}
