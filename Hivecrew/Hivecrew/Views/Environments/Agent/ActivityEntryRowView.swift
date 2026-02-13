//
//  ActivityEntryRowView.swift
//  Hivecrew
//
//  Row view for individual agent activity entries
//

import SwiftUI

/// Individual activity entry row
struct ActivityEntryRow: View {
    let entry: AgentActivityEntry
    let isSelected: Bool
    
    private var iconName: String {
        switch entry.type {
        case .observation: return "camera"
        case .toolCall: return "hammer"
        case .toolResult: return "checkmark.circle"
        case .llmRequest: return "arrow.up.circle"
        case .llmResponse: return "arrow.down.circle"
        case .userQuestion: return "questionmark.circle"
        case .userAnswer: return "person.circle"
        case .error: return "exclamationmark.triangle"
        case .info: return "info.circle"
        case .subagent: return "person.2.fill"
        }
    }
    
    private var iconColor: Color {
        switch entry.type {
        case .observation: return .blue
        case .toolCall: return .orange
        case .toolResult: return .green
        case .llmRequest: return .purple
        case .llmResponse: return .purple
        case .userQuestion: return .yellow
        case .userAnswer: return .cyan
        case .error: return .red
        case .info: return .gray
        case .subagent: return .indigo
        }
    }
    
    private var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: entry.timestamp)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                    .font(.caption)
                    .frame(width: 16)
                
                Text(timeString)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 60, alignment: .leading)
                
                Text(entry.summary)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(isSelected ? nil : 1)
                
                Spacer()
            }
            
            if isSelected, let details = entry.details {
                Text(details)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 84)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
