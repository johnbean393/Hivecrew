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
                            if let pct = context.state.completionPercent {
                                Text("\(pct)%")
                                    .font(.caption.bold())
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let pct = context.state.completionPercent {
                        completionRing(percent: pct)
                    } else if let steps = context.state.stepCount {
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
                if let pct = context.state.completionPercent {
                    Text("\(pct)%")
                        .font(.caption2.bold())
                        .monospacedDigit()
                } else {
                    statusPill(context.state.status)
                }
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

            if let pct = context.state.completionPercent {
                completionRing(percent: pct)
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

    private func completionRing(percent: Int) -> some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.2), lineWidth: 3)
            Circle()
                .trim(from: 0, to: Double(percent) / 100.0)
                .stroke(Color.green, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(percent)%")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .frame(width: 34, height: 34)
    }
}
