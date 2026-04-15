//
//  TaskLiveActivityView.swift
//  HivelinkWidgets
//
//  ActivityConfiguration rendering for Dynamic Island and Lock Screen.
//

import ActivityKit
import SwiftUI
import WidgetKit

struct TaskLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TaskActivityAttributes.self) { context in
            lockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    statusIndicator(for: context.state.status)
                        .font(.title2)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.taskTitle)
                            .font(.headline)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            statusPill(context.state.status)
                            Text(formattedElapsed(context.state.elapsedSeconds))
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let steps = context.state.stepCount {
                        VStack(spacing: 0) {
                            Text("\(steps)")
                                .font(.title3.bold())
                            Text("steps")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.needsAttention, let msg = context.state.attentionMessage {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(msg)
                                .font(.caption)
                                .lineLimit(1)
                        }
                        .padding(.top, 4)
                    }
                }
            } compactLeading: {
                statusIndicator(for: context.state.status)
            } compactTrailing: {
                Text(formattedElapsed(context.state.elapsedSeconds))
                    .font(.caption2)
                    .monospacedDigit()
            } minimal: {
                statusIndicator(for: context.state.status)
            }
        }
    }

    // MARK: - Lock Screen banner

    private func lockScreenView(context: ActivityViewContext<TaskActivityAttributes>) -> some View {
        HStack(spacing: 12) {
            statusIndicator(for: context.state.status)
                .font(.title2)

            VStack(alignment: .leading, spacing: 2) {
                Text(context.attributes.taskTitle)
                    .font(.headline)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    statusPill(context.state.status)

                    if !context.attributes.peerName.isEmpty {
                        Label(context.attributes.peerName, systemImage: "desktopcomputer")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(formattedElapsed(context.state.elapsedSeconds))
                    .font(.subheadline.monospacedDigit())
                if let steps = context.state.stepCount {
                    Text("\(steps) steps")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
    }

    // MARK: - Helpers

    private func statusIndicator(for status: String) -> some View {
        Image(systemName: "circle.fill")
            .foregroundStyle(statusColor(for: status))
    }

    private func statusPill(_ status: String) -> some View {
        Text(status)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(statusColor(for: status).opacity(0.2), in: Capsule())
            .foregroundStyle(statusColor(for: status))
    }

    private func statusColor(for status: String) -> Color {
        switch status.lowercased() {
        case "in progress": return .green
        case "queued", "awaiting vm", "paused", "generating plan": return .yellow
        case "completed": return .gray
        case "failed", "planning failed": return .red
        case "timed out", "max iterations": return .orange
        case "review plan", "review changes": return .blue
        default: return .secondary
        }
    }

    private func formattedElapsed(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
