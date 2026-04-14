//
//  TaskRowView.swift
//  Hivelink
//

import HivecrewCore
import SwiftUI

struct TaskRowView: View {
    let task: TaskRecord

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusDot
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(displayTitle)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    HStack(spacing: 6) {
                        if needsAttention {
                            Circle()
                                .fill(Color.orange.opacity(0.95))
                                .frame(width: 8, height: 8)
                                .accessibilityLabel(String(localized: "Needs attention"))
                        }
                        Text(Self.relativeFormatter.localizedString(for: task.createdAt, relativeTo: Date()))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 8) {
                    Text(providerModelPillText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())

                    if let peer = task.clusterPeerName, !peer.isEmpty {
                        Text(String(localized: "on \(peer)", comment: "Peer name suffix"))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var displayTitle: String {
        let t = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let d = task.taskDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty {
            return truncatedDescription(d)
        }
        if t == String(localized: "Task"), !d.isEmpty {
            return truncatedDescription(d)
        }
        return t
    }

    private func truncatedDescription(_ d: String) -> String {
        guard !d.isEmpty else { return String(localized: "Untitled") }
        if d.count <= 120 { return d }
        return String(d.prefix(120)) + "…"
    }

    private var providerModelPillText: String {
        let provider = Self.displayProviderName(task.providerId)
        let model = task.modelId
        if model.isEmpty { return provider }
        return "\(provider) · \(model)"
    }

    private static func displayProviderName(_ id: String) -> String {
        if id.hasPrefix(TaskRecord.remoteOnlyProviderPrefix) {
            let raw = String(id.dropFirst(TaskRecord.remoteOnlyProviderPrefix.count))
            return raw.isEmpty ? id : raw
        }
        return id.isEmpty ? String(localized: "Unknown") : id
    }

    /// Proxy for pending user input: plan/writeback review and paused need attention.
    private var needsAttention: Bool {
        switch task.status {
        case .paused, .planReview, .writebackReview:
            return true
        default:
            return false
        }
    }

    @ViewBuilder
    private var statusDot: some View {
        Circle()
            .fill(statusDotColor)
            .frame(width: 12, height: 12)
            .overlay {
                Circle()
                    .strokeBorder(.white.opacity(0.35), lineWidth: 0.5)
            }
            .shadow(color: statusDotColor.opacity(0.45), radius: 2, y: 1)
            .accessibilityLabel(task.status.displayName)
    }

    private var statusDotColor: Color {
        switch task.status {
        case .completed:
            if task.wasSuccessful == true {
                return Color(red: 0.2, green: 0.78, blue: 0.35)
            }
            return Color(.tertiaryLabel)
        case .running:
            return Color(red: 0.0, green: 0.48, blue: 1.0)
        case .planReview, .writebackReview:
            return Color(red: 0.0, green: 0.55, blue: 1.0)
        case .planning:
            return Color(red: 0.58, green: 0.32, blue: 0.95)
        case .failed, .planFailed:
            return Color(red: 1.0, green: 0.45, blue: 0.12)
        case .timedOut, .maxIterations:
            return Color(red: 1.0, green: 0.45, blue: 0.12)
        case .paused, .waitingForVM:
            return Color(red: 1.0, green: 0.82, blue: 0.0)
        case .queued:
            return Color(.tertiaryLabel)
        case .cancelled:
            return Color(.tertiaryLabel)
        }
    }
}

#Preview {
    List {
        TaskRowView(task: TaskRecord(
            id: "1",
            title: "Sample task title",
            taskDescription: "Do something useful",
            status: .running,
            providerId: "cluster-remote:Anthropic",
            modelId: "claude-3-5-sonnet"
        ))
    }
    .listStyle(.plain)
}
