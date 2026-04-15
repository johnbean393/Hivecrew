//
//  TaskRowView.swift
//  Hivelink
//

import HivecrewCore
import SwiftUI
import Combine

struct TaskRowView: View {
    let task: TaskRecord

    @EnvironmentObject private var peerConnectionManager: PeerConnectionManager

    private var hasPendingQuestion: Bool {
        peerConnectionManager.pendingQuestion(for: task.id) != nil
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title.isEmpty ? truncatedDescription : task.title)
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                metadataRow
            }

            Spacer(minLength: 0)

            if hasPendingQuestion {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.orange)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.25), value: hasPendingQuestion)
    }

    // MARK: - Status Icon

    @ViewBuilder
    private var statusIcon: some View {
        switch task.status {
        case .queued:
            Image(systemName: "clock.fill")
                .foregroundStyle(.yellow)
                .font(.system(size: 12))

        case .waitingForVM:
            Image(systemName: "desktopcomputer")
                .foregroundStyle(.yellow)
                .font(.system(size: 12))

        case .planning:
            ProgressView()
                .scaleEffect(0.55)

        case .planReview:
            Image(systemName: "list.bullet.clipboard.fill")
                .foregroundStyle(.blue)
                .font(.system(size: 12))

        case .writebackReview:
            Image(systemName: "square.and.arrow.down.on.square.fill")
                .foregroundStyle(.blue)
                .font(.system(size: 12))

        case .running:
            Image(systemName: "play.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 12))

        case .completed:
            if let success = task.wasSuccessful {
                Image(systemName: success ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(success ? .green : .red)
                    .font(.system(size: 12))
            } else {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
            }

        case .failed, .planFailed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 12))

        case .timedOut:
            Image(systemName: "clock.badge.exclamationmark.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 12))

        case .maxIterations:
            Image(systemName: "arrow.trianglehead.2.counterclockwise.rotate.90")
                .foregroundStyle(.orange)
                .font(.system(size: 12))

        case .cancelled:
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))

        case .paused:
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.yellow)
                .font(.system(size: 12))
        }
    }

    // MARK: - Metadata Row

    private var metadataRow: some View {
        HStack(spacing: 0) {
            statusIcon
                .frame(width: 14, height: 14)

            if let nodeName = task.remoteNodeDisplayName {
                metadataSeparator
                HStack(spacing: 3) {
                    Image(systemName: "server.rack")
                        .font(.caption2)
                    Text(nodeName)
                        .font(.caption)
                }
                .foregroundStyle(.blue)
            } else if let peer = task.clusterPeerName, !peer.isEmpty {
                metadataSeparator
                HStack(spacing: 3) {
                    Image(systemName: "server.rack")
                        .font(.caption2)
                    Text(peer)
                        .font(.caption)
                }
                .foregroundStyle(.blue)
            }

            if !task.status.isActive, task.completedAt != nil {
                metadataSeparator
                Text(task.durationString)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if task.status == .running, let startedAt = task.startedAt {
                metadataSeparator
                ElapsedTimeLabel(startDate: startedAt)
            }

            if !task.status.isActive, let outputPaths = task.outputFilePaths, !outputPaths.isEmpty {
                metadataSeparator
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

    private var metadataSeparator: some View {
        Text(" · ")
            .font(.caption)
            .foregroundStyle(.tertiary)
    }

    // MARK: - Helpers

    private var truncatedDescription: String {
        let d = task.taskDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !d.isEmpty else { return String(localized: "Untitled") }
        if d.count <= 120 { return d }
        return String(d.prefix(120)) + "…"
    }

}

// MARK: - Elapsed Time Label

private struct ElapsedTimeLabel: View {
    let startDate: Date
    @State private var elapsed: TimeInterval = 0

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(formattedElapsed)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .monospacedDigit()
            .onReceive(timer) { _ in
                elapsed = Date().timeIntervalSince(startDate)
            }
            .onAppear {
                elapsed = Date().timeIntervalSince(startDate)
            }
    }

    private var formattedElapsed: String {
        let seconds = Int(elapsed)
        if seconds < 60 {
            return "\(seconds)s"
        } else if seconds < 3600 {
            return "\(seconds / 60)m \(seconds % 60)s"
        } else {
            let hours = seconds / 3600
            let minutes = (seconds % 3600) / 60
            return "\(hours)h \(minutes)m"
        }
    }
}

#Preview {
    List {
        TaskRowView(task: {
            let t = TaskRecord(
                id: "1",
                title: "Create `txt` Hello World File",
                taskDescription: "Create a hello world text file",
                status: .completed,
                completedAt: Date(),
                providerId: "cluster-remote:Anthropic",
                modelId: "claude-3-5-sonnet"
            )
            t.wasSuccessful = true
            return t
        }())
        TaskRowView(task: TaskRecord(
            id: "2",
            title: "Research Paris Trip",
            taskDescription: "Find the best restaurants",
            status: .running,
            startedAt: Date().addingTimeInterval(-125),
            providerId: "cluster-remote:OpenAI",
            modelId: "gpt-5.4"
        ))
        TaskRowView(task: TaskRecord(
            id: "3",
            title: "Solve Cold Fusion",
            taskDescription: "Invent nuclear fusion",
            status: .failed,
            completedAt: Date(),
            providerId: "test",
            modelId: "kimi-k2.5",
            errorMessage: "Task is impossible"
        ))
    }
    .listStyle(.plain)
    .environmentObject(PeerConnectionManager(
        remoteTaskIndex: RemoteTaskIndex(),
        clusterCoordinator: HivelinkClusterCoordinator()
    ))
}
