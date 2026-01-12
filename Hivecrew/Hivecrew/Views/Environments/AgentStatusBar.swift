//
//  AgentStatusBar.swift
//  Hivecrew
//
//  Status bar showing agent connection and token usage
//

import SwiftUI

/// Status bar for agent state
struct AgentStatusBar: View {
    @ObservedObject var statePublisher: AgentStatePublisher
    let connectionState: GuestAgentConnection.ConnectionState?
    
    var body: some View {
        HStack(spacing: 16) {
            // Connection status
            HStack(spacing: 4) {
                Circle()
                    .fill(connectionColor)
                    .frame(width: 8, height: 8)
                Text(connectionText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Divider()
                .frame(height: 12)
            
            // Agent status
            if statePublisher.status != .idle {
                HStack(spacing: 4) {
                    Circle()
                        .fill(agentStatusColor)
                        .frame(width: 8, height: 8)
                    Text("Agent: \(statePublisher.status.rawValue.capitalized)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Divider()
                    .frame(height: 12)
            }
            
            // Token usage
            if statePublisher.totalTokens > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "textformat.123")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("\(formatNumber(statePublisher.totalTokens)) tokens")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            // Current tool
            if let tool = statePublisher.currentToolCall {
                Divider()
                    .frame(height: 12)
                
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.3)
                        .frame(width: 12, height: 12)
                    Text(tool)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }
    
    private var connectionColor: Color {
        guard let state = connectionState else { return .gray }
        switch state {
        case .disconnected: return .gray
        case .connecting: return .yellow
        case .connected: return .green
        case .error: return .red
        }
    }
    
    private var connectionText: String {
        guard let state = connectionState else { return "No Connection" }
        switch state {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .connected: return "Connected"
        case .error(let msg): return "Error: \(msg)"
        }
    }
    
    private var agentStatusColor: Color {
        switch statePublisher.status {
        case .idle: return .gray
        case .connecting: return .yellow
        case .running: return .green
        case .paused: return .yellow
        case .completed: return .blue
        case .failed: return .red
        case .cancelled: return .orange
        }
    }
    
    private func formatNumber(_ n: Int) -> String {
        if n >= 1000 {
            return String(format: "%.1fk", Double(n) / 1000.0)
        }
        return "\(n)"
    }
}

#Preview {
    let publisher = AgentStatePublisher(taskId: "test")
    publisher.status = .running
    publisher.currentStep = 5
    publisher.promptTokens = 1250
    publisher.completionTokens = 350
    publisher.totalTokens = 1600
    publisher.currentToolCall = "mouse_click"
    
    return AgentStatusBar(
        statePublisher: publisher,
        connectionState: .connected
    )
    .frame(width: 600)
}
