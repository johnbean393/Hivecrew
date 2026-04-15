//
//  HistoricalTraceEventRow.swift
//  Hivelink
//
//  Renders a TraceEventInfo from a parsed trace.jsonl file.
//  Reports scroll-position visibility via VisibleEventPreferenceKey
//  so the parent view can sync the screenshot viewer.
//

import HivecrewCore
import SwiftUI

struct HistoricalTraceEventRow: View {
    let event: TraceEventInfo
    let index: Int

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard hasExpandableContent else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                mainRow
            }
            .buttonStyle(.plain)

            if isExpanded, hasExpandableContent {
                expandedDetail
                    .padding(.leading, 28)
                    .padding(.top, 6)
                    .padding(.bottom, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .overlay {
            GeometryReader { geo in
                let frame = geo.frame(in: .named("traceScroll"))
                Color.clear
                    .preference(
                        key: VisibleEventPreferenceKey.self,
                        value: [EventVisibility(
                            id: event.id,
                            index: index,
                            minY: frame.minY,
                            maxY: frame.maxY
                        )]
                    )
            }
        }
    }

    // MARK: - Main row

    private var mainRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .font(.caption)
                .foregroundStyle(iconColor)
                .frame(width: 20, alignment: .center)

            Text(event.summary)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                if event.tokenUsage.hasUsage {
                    Text("\(event.tokenUsage.effectiveTotal)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }

                Text(formattedTimestamp)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            if hasExpandableContent {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
        }
    }

    // MARK: - Expanded detail

    @ViewBuilder
    private var expandedDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let details = event.details, !details.isEmpty {
                detailBlock(label: "Details", value: details)
            }

            if let reasoning = event.reasoning, !reasoning.isEmpty {
                detailBlock(label: "Reasoning", value: reasoning)
            }

            if let response = event.responseText, !response.isEmpty {
                detailBlock(label: "Response", value: response)
            }

            if event.tokenUsage.hasUsage {
                HStack(spacing: 12) {
                    tokenLabel("In", count: event.tokenUsage.prompt)
                    tokenLabel("Out", count: event.tokenUsage.completion)
                    if event.tokenUsage.reasoningTokens > 0 {
                        tokenLabel("Reasoning", count: event.tokenUsage.reasoningTokens)
                    }
                }
            }

            if let subagentId = event.subagentId {
                HStack(spacing: 4) {
                    Text("Subagent:")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(subagentId)
                        .font(.caption)
                        .foregroundStyle(.primary)
                    if let status = event.subagentStatus {
                        Text("(\(status))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func detailBlock(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(12)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func tokenLabel(_ label: String, count: Int) -> some View {
        HStack(spacing: 2) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tertiary)
            Text("\(count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Derived properties

    private var iconName: String {
        switch event.type {
        case "session_start": return "play.circle.fill"
        case "session_end": return "stop.circle.fill"
        case "observation": return "camera.fill"
        case "llm_request": return "arrow.up.circle"
        case "llm_response": return "sparkles"
        case "tool_call": return "hammer.fill"
        case "tool_result": return "checkmark.circle.fill"
        case "error": return "exclamationmark.triangle.fill"
        case "custom":
            if event.subagentId != nil { return "person.2.fill" }
            return "gearshape.fill"
        default: return "circle.fill"
        }
    }

    private var iconColor: Color {
        switch event.type {
        case "session_start": return .green
        case "session_end": return .gray
        case "observation": return .purple
        case "llm_request": return .cyan
        case "llm_response": return .indigo
        case "tool_call": return .blue
        case "tool_result": return .green
        case "error": return .red
        case "custom":
            if event.subagentId != nil { return .teal }
            return .orange
        default: return Color(.tertiaryLabel)
        }
    }

    private var formattedTimestamp: String {
        // timestamp is ISO-8601 string; extract HH:mm:ss
        if event.timestamp.count >= 19 {
            let start = event.timestamp.index(event.timestamp.startIndex, offsetBy: 11)
            let end = event.timestamp.index(start, offsetBy: 8, limitedBy: event.timestamp.endIndex) ?? event.timestamp.endIndex
            return String(event.timestamp[start..<end])
        }
        return event.timestamp
    }

    private var hasExpandableContent: Bool {
        (event.details != nil && !(event.details?.isEmpty ?? true))
            || (event.reasoning != nil && !(event.reasoning?.isEmpty ?? true))
            || (event.responseText != nil && !(event.responseText?.isEmpty ?? true))
            || event.tokenUsage.hasUsage
            || event.subagentId != nil
    }
}

#Preview {
    ScrollView {
        VStack(spacing: 0) {
            HistoricalTraceEventRow(
                event: TraceEventInfo(
                    id: "1",
                    type: "tool_call",
                    timestamp: "2026-04-14T10:30:15Z",
                    step: 1,
                    summary: "Running build script",
                    rawJSON: "{}"
                ),
                index: 0
            )
            Divider().padding(.leading, 44)
            HistoricalTraceEventRow(
                event: TraceEventInfo(
                    id: "2",
                    type: "llm_response",
                    timestamp: "2026-04-14T10:30:20Z",
                    step: 2,
                    summary: "Analyzing project structure",
                    rawJSON: "{}",
                    tokenUsage: TraceTokenUsage(prompt: 1500, completion: 420, total: 1920)
                ),
                index: 1
            )
        }
    }
    .coordinateSpace(name: "traceScroll")
}
