//
//  MCPServerRowView.swift
//  Hivecrew
//
//  Row for a configured MCP server
//

import SwiftUI
import HivecrewMCP

struct MCPServerRow: View {
    let server: MCPServerRecord
    let connectionState: MCPConnectionState
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onToggle: (Bool) -> Void
    let onConnect: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            statusIndicator
            
            VStack(alignment: .leading, spacing: 2) {
                Text(server.displayName)
                    .fontWeight(.medium)
                
                Text(serverDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Toggle("", isOn: Binding(
                get: { server.isEnabled },
                set: { onToggle($0) }
            ))
            .labelsHidden()
            
            Menu {
                Button("Edit...") {
                    onEdit()
                }
                
                if server.isEnabled {
                    Button("Reconnect") {
                        onConnect()
                    }
                }
                
                Divider()
                
                Button("Delete", role: .destructive) {
                    onDelete()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundColor(.secondary)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
        }
        .padding(.vertical, 4)
    }
    
    private var statusIndicator: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
    }
    
    private var statusColor: Color {
        guard server.isEnabled else { return .gray }
        
        switch connectionState {
        case .disconnected: return .gray
        case .connecting: return .yellow
        case .connected: return .green
        case .error: return .red
        }
    }
    
    private var serverDescription: String {
        switch server.transportType {
        case .stdio:
            if let command = server.command {
                let args = server.arguments.joined(separator: " ")
                return "\(command) \(args)".prefix(50).description
            }
            return "Standard I/O"
        case .http:
            return server.serverURL ?? "HTTP"
        }
    }
}
