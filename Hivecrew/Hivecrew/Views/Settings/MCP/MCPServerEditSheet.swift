//
//  MCPServerEditSheet.swift
//  Hivecrew
//
//  Sheet for adding or editing an MCP server configuration
//

import SwiftUI
import SwiftData
import HivecrewMCP

/// Mode for the edit sheet
enum MCPServerEditMode: Identifiable {
    case add
    case edit(MCPServerRecord)
    
    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let server): return server.id
        }
    }
    
    var title: String {
        switch self {
        case .add: return "Add MCP Server"
        case .edit: return "Edit MCP Server"
        }
    }
}

/// Sheet for adding or editing an MCP server configuration
struct MCPServerEditSheet: View {
    
    // MARK: - Properties
    
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    
    let mode: MCPServerEditMode
    
    // MARK: - State
    
    @State private var displayName: String = ""
    @State private var transportType: MCPServerTransportType = .stdio
    
    // Stdio config
    @State private var command: String = ""
    @State private var argumentsText: String = ""
    @State private var workingDirectory: String = ""
    @State private var environmentText: String = ""
    
    // HTTP config
    @State private var serverURL: String = ""
    
    @State private var isEnabled: Bool = true
    @State private var isTesting: Bool = false
    @State private var testResult: TestResult?
    
    enum TestResult {
        case success(toolCount: Int)
        case failure(String)
    }
    
    // MARK: - Computed Properties
    
    private var isValid: Bool {
        guard !displayName.isEmpty else { return false }
        
        switch transportType {
        case .stdio:
            return !command.isEmpty
        case .http:
            return URL(string: serverURL) != nil
        }
    }
    
    // MARK: - Body
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            header
            
            Divider()
            
            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    basicInfoSection
                    transportSection
                    
                    if case .edit = mode {
                        advancedSection
                    }
                }
                .padding()
            }
            
            Divider()
            
            // Footer
            footer
        }
        .frame(width: 500, height: 480)
        .onAppear {
            loadExistingData()
        }
    }
    
    // MARK: - Header
    
    private var header: some View {
        HStack {
            Text(mode.title)
                .font(.headline)
            Spacer()
        }
        .padding()
    }
    
    // MARK: - Sections
    
    private var basicInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Basic Information")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Name")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("My MCP Server", text: $displayName)
                    .textFieldStyle(.roundedBorder)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Transport")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("", selection: $transportType) {
                    ForEach(MCPServerTransportType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            
            Toggle("Enabled", isOn: $isEnabled)
        }
    }
    
    private var transportSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connection")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
            
            switch transportType {
            case .stdio:
                stdioConfigSection
            case .http:
                httpConfigSection
            }
        }
    }
    
    private var stdioConfigSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Command")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("npx", text: $command)
                    .textFieldStyle(.roundedBorder)
                Text("The executable to run (e.g., npx, node, python)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Arguments")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("-y @modelcontextprotocol/server-filesystem /path/to/dir", text: $argumentsText)
                    .textFieldStyle(.roundedBorder)
                Text("Space-separated arguments passed to the command")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Working Directory (optional)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack {
                    TextField("", text: $workingDirectory)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse...") {
                        selectWorkingDirectory()
                    }
                }
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Environment Variables (optional)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextEditor(text: $environmentText)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 60)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
                Text("One per line: KEY=value")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private var httpConfigSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Server URL")
                .font(.caption)
                .foregroundColor(.secondary)
            TextField("http://localhost:3000/mcp", text: $serverURL)
                .textFieldStyle(.roundedBorder)
            Text("The HTTP endpoint of the MCP server")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
    
    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Test Connection")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
            
            HStack {
                Button("Test Connection") {
                    testConnection()
                }
                .disabled(!isValid || isTesting)
                
                if isTesting {
                    ProgressView()
                        .scaleEffect(0.7)
                }
                
                if let result = testResult {
                    testResultView(result)
                }
            }
        }
    }
    
    @ViewBuilder
    private func testResultView(_ result: TestResult) -> some View {
        switch result {
        case .success(let toolCount):
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Connected - \(toolCount) tools available")
                    .font(.caption)
                    .foregroundColor(.green)
            }
        case .failure(let error):
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(1)
            }
        }
    }
    
    // MARK: - Footer
    
    private var footer: some View {
        HStack {
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.escape, modifiers: [])
            
            Spacer()
            
            Button("Save") {
                save()
                dismiss()
            }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(!isValid)
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
    
    // MARK: - Actions
    
    private func loadExistingData() {
        if case .edit(let server) = mode {
            displayName = server.displayName
            transportType = server.transportType
            isEnabled = server.isEnabled
            command = server.command ?? ""
            argumentsText = server.arguments.joined(separator: " ")
            workingDirectory = server.workingDirectory ?? ""
            environmentText = server.environment.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
            serverURL = server.serverURL ?? ""
        }
    }
    
    private func save() {
        let arguments = parseArguments(argumentsText)
        let environment = parseEnvironment(environmentText)
        
        var serverIdToConnect: String?
        
        switch mode {
        case .add:
            let server = MCPServerRecord(
                displayName: displayName,
                isEnabled: isEnabled,
                transportType: transportType,
                command: transportType == .stdio ? command : nil,
                arguments: transportType == .stdio ? arguments : nil,
                workingDirectory: transportType == .stdio && !workingDirectory.isEmpty ? workingDirectory : nil,
                environment: transportType == .stdio && !environment.isEmpty ? environment : nil,
                serverURL: transportType == .http ? serverURL : nil
            )
            modelContext.insert(server)
            
            // Auto-connect new enabled servers
            if isEnabled {
                serverIdToConnect = server.id
            }
            
        case .edit(let server):
            let wasEnabled = server.isEnabled
            
            server.displayName = displayName
            server.transportType = transportType
            server.isEnabled = isEnabled
            server.command = transportType == .stdio ? command : nil
            server.arguments = transportType == .stdio ? arguments : []
            server.workingDirectory = transportType == .stdio && !workingDirectory.isEmpty ? workingDirectory : nil
            server.environment = transportType == .stdio && !environment.isEmpty ? environment : [:]
            server.serverURL = transportType == .http ? serverURL : nil
            
            // Reconnect if configuration changed while enabled
            if isEnabled {
                serverIdToConnect = server.id
            } else if wasEnabled && !isEnabled {
                // Disconnect if disabled
                Task {
                    await MCPServerManager.shared.disconnect(from: server.id)
                }
            }
        }
        
        try? modelContext.save()
        
        // Connect after saving so the record is persisted
        if let serverId = serverIdToConnect {
            Task {
                await MCPServerManager.shared.reconnect(serverId: serverId)
            }
        }
    }
    
    private func testConnection() {
        isTesting = true
        testResult = nil
        
        Task {
            do {
                let config = MCPServerConfig(
                    name: displayName,
                    transportType: transportType == .stdio ? .stdio : .http,
                    command: command,
                    arguments: parseArguments(argumentsText),
                    workingDirectory: workingDirectory.isEmpty ? nil : workingDirectory,
                    environment: parseEnvironment(environmentText).isEmpty ? nil : parseEnvironment(environmentText),
                    serverURL: serverURL
                )
                
                let connection = MCPServerConnection(config: config)
                try await connection.connect()
                
                let tools = await connection.tools
                await connection.disconnect()
                
                await MainActor.run {
                    testResult = .success(toolCount: tools.count)
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    testResult = .failure(error.localizedDescription)
                    isTesting = false
                }
            }
        }
    }
    
    private func selectWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        
        if panel.runModal() == .OK, let url = panel.url {
            workingDirectory = url.path
        }
    }
    
    // MARK: - Parsing Helpers
    
    private func parseArguments(_ text: String) -> [String] {
        text.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
    }
    
    private func parseEnvironment(_ text: String) -> [String: String] {
        var env: [String: String] = [:]
        let lines = text.components(separatedBy: .newlines)
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            
            if let eqIndex = trimmed.firstIndex(of: "=") {
                let key = String(trimmed[..<eqIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[trimmed.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)
                if !key.isEmpty {
                    env[key] = value
                }
            }
        }
        
        return env
    }
}

// MARK: - Preview

#Preview("Add Mode") {
    MCPServerEditSheet(mode: .add)
        .modelContainer(for: MCPServerRecord.self, inMemory: true)
}
