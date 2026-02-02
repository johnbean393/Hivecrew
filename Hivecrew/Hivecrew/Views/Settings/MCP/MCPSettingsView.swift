//
//  MCPSettingsView.swift
//  Hivecrew
//
//  Settings view for managing MCP (Model Context Protocol) servers
//

import SwiftUI
import SwiftData
import HivecrewMCP

/// Settings view for configuring MCP servers
struct MCPSettingsView: View {
    
    // MARK: - State
    
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MCPServerRecord.sortOrder) private var servers: [MCPServerRecord]
    
    @StateObject private var mcpManager = MCPServerManager.shared
    
    @State private var showAddSheet = false
    @State private var editingServer: MCPServerRecord?
    @State private var serverToDelete: MCPServerRecord?
    @State private var showDeleteConfirmation = false
    
    // MARK: - Body
    
    var body: some View {
        Form {
            serverListSection
            presetsSection
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showAddSheet) {
            MCPServerEditSheet(mode: .add)
        }
        .sheet(item: $editingServer) { server in
            MCPServerEditSheet(mode: .edit(server))
        }
        .alert("Delete Server?", isPresented: $showDeleteConfirmation, presenting: serverToDelete) { server in
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                deleteServer(server)
            }
        } message: { server in
            Text("Are you sure you want to delete '\(server.displayName)'? This cannot be undone.")
        }
    }
    
    // MARK: - Server List Section
    
    private var serverListSection: some View {
        Section {
            if servers.isEmpty {
                ContentUnavailableView {
                    Label("No MCP Servers", systemImage: "puzzlepiece.extension")
                } description: {
                    Text("Add MCP servers to extend the agent's capabilities with external tools.")
                } actions: {
                    Button("Add Server") {
                        showAddSheet = true
                    }
                }
                .frame(height: 150)
            } else {
                ForEach(servers) { server in
                    MCPServerRow(
                        server: server,
                        connectionState: mcpManager.serverStates[server.id] ?? .disconnected,
                        onEdit: { editingServer = server },
                        onDelete: {
                            serverToDelete = server
                            showDeleteConfirmation = true
                        },
                        onToggle: { enabled in
                            server.isEnabled = enabled
                            try? modelContext.save()
                            
                            // Auto-connect or disconnect based on toggle
                            Task {
                                if enabled {
                                    await mcpManager.reconnect(serverId: server.id)
                                } else {
                                    await mcpManager.disconnect(from: server.id)
                                }
                            }
                        },
                        onConnect: {
                            Task {
                                await mcpManager.reconnect(serverId: server.id)
                            }
                        }
                    )
                }
            }
        } header: {
            HStack {
                Text("MCP Servers")
                Spacer()
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
            }
        } footer: {
            Text("MCP servers provide additional tools that the agent can use during task execution. Tools from enabled servers are automatically available.")
        }
    }
    
    // MARK: - Presets Section
    
    private var presetsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Quick Add")
                    .font(.headline)
                
                HStack(spacing: 12) {
                    PresetButton(name: "Filesystem", icon: "folder") {
                        addPreset(.filesystemPreset())
                    }
                    PresetButton(name: "GitHub", icon: "chevron.left.forwardslash.chevron.right") {
                        addPreset(.githubPreset())
                    }
                    PresetButton(name: "Brave Search", icon: "magnifyingglass") {
                        addPreset(.braveSearchPreset())
                    }
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Presets")
        } footer: {
            Text("These presets require Node.js and npx to be installed on your system.")
        }
    }
    
    // MARK: - Actions
    
    private func deleteServer(_ server: MCPServerRecord) {
        Task {
            await mcpManager.disconnect(from: server.id)
        }
        modelContext.delete(server)
        try? modelContext.save()
    }
    
    private func addPreset(_ preset: MCPServerRecord) {
        // Check if a server with this name already exists
        if servers.contains(where: { $0.displayName == preset.displayName }) {
            return
        }
        
        preset.sortOrder = servers.count
        modelContext.insert(preset)
        try? modelContext.save()
    }
}

// MARK: - Server Row

private struct MCPServerRow: View {
    let server: MCPServerRecord
    let connectionState: MCPConnectionState
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onToggle: (Bool) -> Void
    let onConnect: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // Status indicator
            statusIndicator
            
            // Server info
            VStack(alignment: .leading, spacing: 2) {
                Text(server.displayName)
                    .fontWeight(.medium)
                
                Text(serverDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // Enable toggle
            Toggle("", isOn: Binding(
                get: { server.isEnabled },
                set: { onToggle($0) }
            ))
            .labelsHidden()
            
            // Actions menu
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

// MARK: - Preset Button

private struct PresetButton: View {
    let name: String
    let icon: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                Text(name)
                    .font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.1))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

#Preview {
    MCPSettingsView()
        .modelContainer(for: MCPServerRecord.self, inMemory: true)
        .frame(width: 550, height: 450)
}
