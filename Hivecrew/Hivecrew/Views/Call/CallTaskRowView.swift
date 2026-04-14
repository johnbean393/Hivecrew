//
//  CallTaskRowView.swift
//  Hivecrew
//
//  A row in the call task pane showing worker name, role, and status.
//  Visual styling mirrors the Dashboard TaskRowView (rounded background, border,
//  status indicators) but with a simplified interaction model for the call pane.
//

import SwiftUI
import HivecrewCore

struct CallTaskRowView: View {

    let task: TaskRecord
    var onSelect: (() -> Void)?

    @EnvironmentObject var orchestrator: VoiceOrchestrator
    @EnvironmentObject var taskService: TaskService
    @State private var isHovered = false

    init(task: TaskRecord, onSelect: (() -> Void)? = nil) {
        self.task = task
        self.onSelect = onSelect
    }

    private var worker: WorkerIdentity? {
        orchestrator.workerRegistry.workers.first(where: { $0.id == task.id })
    }

    private var effectiveStatus: TaskStatus {
        taskService.effectiveStatus(for: task)
    }

    private var statusColor: Color {
        switch effectiveStatus {
        case .queued, .waitingForVM, .paused, .planning:
            return .yellow
        case .running:
            return .green
        case .completed:
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
        case .planReview, .writebackReview:
            return .blue
        }
    }

    private var completionIcon: String? {
        guard effectiveStatus == .completed else { return nil }
        if let success = task.wasSuccessful {
            return success ? "checkmark.circle.fill" : "xmark.circle.fill"
        }
        return nil
    }

    var body: some View {
        Button { onSelect?() } label: {
            rowContent
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isHovered ? Color.secondary.opacity(0.6) : Color.secondary.opacity(0.4), lineWidth: 1)
        )
        .onHover { isHovered = $0 }
    }

    private var rowContent: some View {
        HStack(spacing: 12) {
            statusIndicator

            VStack(alignment: .leading, spacing: 2) {
                Text(worker?.label ?? task.title)
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    if effectiveStatus == .completed, let success = task.wasSuccessful {
                        Text(success ? "Verified Complete" : "Incomplete")
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

                    if !effectiveStatus.isActive,
                       let outputPaths = task.outputFilePaths,
                       !outputPaths.isEmpty {
                        Text("•")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        HStack(spacing: 3) {
                            Image(systemName: "doc.fill")
                                .font(.caption2)
                            Text("\(outputPaths.count)")
                                .font(.caption)
                        }
                        .foregroundStyle(.blue)
                    }
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if effectiveStatus == .planning {
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 14, height: 14)
        } else if effectiveStatus == .planReview {
            Image(systemName: "list.bullet.clipboard.fill")
                .foregroundStyle(.blue)
                .font(.system(size: 14))
                .frame(width: 14, height: 14)
        } else if effectiveStatus == .writebackReview {
            Image(systemName: "square.and.arrow.down.on.square.fill")
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
    }
}
