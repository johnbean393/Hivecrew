//
//  TraceEventRow.swift
//  Hivelink
//

import HivecrewAPIModels
import SwiftUI

// MARK: - JSONValue helpers

extension JSONValue {
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var intValue: Int? {
        if case .int(let i) = self { return i }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }
}

// MARK: - TraceEventRow

struct TraceEventRow: View {
    let event: APITaskEvent

    @State private var isExpanded = false

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

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
    }

    private var mainRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .font(.caption)
                .foregroundStyle(iconColor)
                .frame(width: 20, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(summaryText)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                if let subtitle = subtitleText {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                if let tokens = tokenCount {
                    Text("\(tokens)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }

                Text(Self.timestampFormatter.string(from: event.timestamp))
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

    @ViewBuilder
    private var expandedDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let toolName = event.data["tool_name"]?.stringValue {
                detailRow(label: "Tool", value: toolName)
            }

            if let arguments = event.data["arguments"]?.stringValue, !arguments.isEmpty {
                detailBlock(label: "Arguments", value: arguments)
            }

            if let reasoning = event.data["reasoning"]?.stringValue, !reasoning.isEmpty {
                detailBlock(label: "Reasoning", value: reasoning)
            }

            if let output = event.data["output"]?.stringValue, !output.isEmpty {
                detailBlock(label: "Output", value: output)
            }
        }
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label + ":")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
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
                .lineLimit(8)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - Derived properties

    private var iconName: String {
        switch event.type {
        case .screenshot: return "camera.fill"
        case .toolCallStart: return "hammer.fill"
        case .toolCallResult: return "checkmark.circle.fill"
        case .llmResponse: return "sparkles"
        case .statusChange: return "arrow.triangle.2.circlepath"
        case .subagentUpdate: return "person.2.fill"
        case .question: return "questionmark.circle.fill"
        case .permissionRequest: return "exclamationmark.shield.fill"
        }
    }

    private var iconColor: Color {
        switch event.type {
        case .screenshot: return .purple
        case .toolCallStart: return .blue
        case .toolCallResult: return .green
        case .llmResponse: return .indigo
        case .statusChange: return .orange
        case .subagentUpdate: return .teal
        case .question: return .yellow
        case .permissionRequest: return .red
        }
    }

    private var subtitleText: String? {
        if let details = event.data["details"]?.stringValue, !details.isEmpty {
            return details
        }
        switch event.type {
        case .toolCallResult:
            if let tool = event.data["tool_name"]?.stringValue {
                return tool
            }
        case .llmResponse:
            if let usage = event.data["token_usage"]?.objectValue {
                let prompt = usage["input_tokens"]?.intValue ?? usage["prompt_tokens"]?.intValue ?? 0
                let completion = usage["output_tokens"]?.intValue ?? usage["completion_tokens"]?.intValue ?? 0
                let total = prompt + completion
                if total > 0 {
                    return "Tokens: \(total) total (\(prompt) prompt, \(completion) completion)"
                }
            }
        default:
            break
        }
        return nil
    }

    private var summaryText: String {
        if let summary = event.data["summary"]?.stringValue, !summary.isEmpty {
            return summary
        }
        switch event.type {
        case .screenshot: return "Captured screenshot"
        case .toolCallStart:
            if let tool = event.data["tool_name"]?.stringValue {
                return "Executing: \(tool)"
            }
            return "Executing tool"
        case .toolCallResult:
            if let tool = event.data["tool_name"]?.stringValue {
                return "✓ \(tool) completed"
            }
            return "Tool completed"
        case .llmResponse:
            if let toolCount = event.data["tool_call_count"]?.intValue, toolCount > 0 {
                return "LLM requested \(toolCount) tool call\(toolCount == 1 ? "" : "s")"
            }
            return "Sending request to LLM"
        case .statusChange:
            if let status = event.data["status"]?.stringValue {
                return "Status: \(status)"
            }
            return "Status changed"
        case .subagentUpdate: return "Subagent update"
        case .question:
            if let q = event.data["question"]?.stringValue {
                return "Question: \(q)"
            }
            return "Agent question"
        case .permissionRequest:
            if let tool = event.data["tool_name"]?.stringValue {
                return "Permission: \(tool)"
            }
            return "Permission requested"
        }
    }

    private var tokenCount: Int? {
        guard let usage = event.data["token_usage"] else { return nil }
        if let total = usage.intValue { return total }
        if let obj = usage.objectValue {
            let input = obj["input_tokens"]?.intValue ?? 0
            let output = obj["output_tokens"]?.intValue ?? 0
            let total = input + output
            return total > 0 ? total : nil
        }
        return nil
    }

    private var hasExpandableContent: Bool {
        event.data["tool_name"]?.stringValue != nil
            || event.data["arguments"]?.stringValue != nil
            || event.data["reasoning"]?.stringValue != nil
            || event.data["output"]?.stringValue != nil
    }
}

#Preview {
    VStack(spacing: 0) {
        TraceEventRow(event: APITaskEvent(
            type: .toolCallStart,
            data: ["tool_name": "bash", "summary": "Running build script"]
        ))
        Divider()
        TraceEventRow(event: APITaskEvent(
            type: .llmResponse,
            data: ["summary": "Analyzing the project structure", "token_usage": .object(["input_tokens": 150, "output_tokens": 42])]
        ))
        Divider()
        TraceEventRow(event: APITaskEvent(
            type: .screenshot,
            data: ["summary": "Screenshot captured"]
        ))
    }
}
