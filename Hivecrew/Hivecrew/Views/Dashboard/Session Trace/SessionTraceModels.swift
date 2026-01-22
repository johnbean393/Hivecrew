//
//  SessionTraceModels.swift
//  Hivecrew
//
//  Models and supporting views for SessionTraceView
//

import SwiftUI

// MARK: - Event Visibility Tracking

struct EventVisibility: Equatable {
    let id: String
    let index: Int
    let minY: CGFloat
    let maxY: CGFloat
}

struct VisibleEventPreferenceKey: PreferenceKey {
    static var defaultValue: [EventVisibility] = []
    
    static func reduce(value: inout [EventVisibility], nextValue: () -> [EventVisibility]) {
        value.append(contentsOf: nextValue())
    }
}

// MARK: - Trace Event Info

struct TraceEventInfo: Identifiable {
    let id: String
    let type: String
    let timestamp: String
    let step: Int
    let summary: String
    let rawJSON: String
    let screenshotPath: String?
    let details: String?
    /// Full response text from LLM (when responding with text, not tool calls)
    let responseText: String?
    /// Reasoning/thinking content from models that support reasoning tokens (optional for backward compatibility)
    let reasoning: String?
    
    init(id: String, type: String, timestamp: String, step: Int, summary: String, rawJSON: String, screenshotPath: String? = nil, details: String? = nil, responseText: String? = nil, reasoning: String? = nil) {
        self.id = id
        self.type = type
        self.timestamp = timestamp
        self.step = step
        self.summary = summary
        self.rawJSON = rawJSON
        self.screenshotPath = screenshotPath
        self.details = details
        self.responseText = responseText
        self.reasoning = reasoning
    }
}

// MARK: - Historical Trace Event Row

struct HistoricalTraceEventRow: View {
    let event: TraceEventInfo
    let isCurrentScreenshot: Bool
    
    @State private var isExpanded: Bool = false
    @State private var isReasoningExpanded: Bool = false
    
    private var hasScreenshot: Bool {
        event.screenshotPath != nil
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Main row
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.caption)
                    .foregroundStyle(iconColor)
                    .frame(width: 16)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.summary)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(isExpanded ? nil : 2)
                        .textSelection(.enabled)
                    
                    if let details = event.details, !details.isEmpty {
                        Text(details)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(isExpanded ? nil : 2)
                            .textSelection(.enabled)
                    }
                    
                    // Reasoning indicator (collapsed)
                    if let reasoning = event.reasoning, !reasoning.isEmpty, !isExpanded {
                        HStack(spacing: 4) {
                            Image(systemName: "brain")
                                .font(.caption2)
                            Text("Reasoning available")
                                .font(.caption2)
                        }
                        .foregroundStyle(.purple.opacity(0.8))
                    }
                }
                
                Spacer()
                
                // Timestamp
                Text(formatTimestamp(event.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(isCurrentScreenshot ? Color.accentColor.opacity(0.15) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onTapGesture {
                if !hasScreenshot {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                }
            }
            
            // Expanded content
            if isExpanded && !hasScreenshot {
                // JSON view
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(prettyJSON)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 150)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.leading, 24)
                
                // Reasoning section (collapsible)
                if let reasoning = event.reasoning, !reasoning.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                isReasoningExpanded.toggle()
                            }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "brain")
                                    .font(.caption)
                                Text("Reasoning")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Spacer()
                                Image(systemName: isReasoningExpanded ? "chevron.up" : "chevron.down")
                                    .font(.caption2)
                            }
                            .foregroundStyle(.purple)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        
                        if isReasoningExpanded {
                            ScrollView {
                                Text(reasoning)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 200)
                            .background(Color.purple.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding(.leading, 24)
                    .padding(.top, 4)
                }
            }
        }
    }
    
    private var iconName: String {
        switch event.type {
        case "session_start": return "play.circle.fill"
        case "session_end": return "stop.circle.fill"
        case "observation": return "camera.fill"
        case "llm_request": return "arrow.up.circle.fill"
        case "llm_response": return "sparkles"
        case "tool_call": return "hammer.fill"
        case "tool_result": return "checkmark.circle.fill"
        case "error": return "exclamationmark.triangle.fill"
        default: return "circle.fill"
        }
    }
    
    private var iconColor: Color {
        switch event.type {
        case "session_start": return .green
        case "session_end": return .blue
        case "observation": return .cyan
        case "llm_request", "llm_response": return .purple
        case "tool_call", "tool_result": return .orange
        case "error": return .red
        default: return .gray
        }
    }
    
    private func formatTimestamp(_ timestamp: String) -> String {
        let formatter = ISO8601DateFormatter()
        
        // Try with fractional seconds first
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: timestamp) {
            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "HH:mm:ss"
            return timeFormatter.string(from: date)
        }
        
        // Try without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: timestamp) {
            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "HH:mm:ss"
            return timeFormatter.string(from: date)
        }
        
        return timestamp
    }
    
    private var prettyJSON: String {
        guard let data = event.rawJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let prettyData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
              let prettyString = String(data: prettyData, encoding: .utf8) else {
            return event.rawJSON
        }
        return prettyString
    }
}

// MARK: - Safe Array Access

extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
