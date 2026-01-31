//
//  APISettingsView.swift
//  Hivecrew
//
//  Settings view for the REST API server
//

import SwiftUI
import TipKit
import HivecrewAPI

/// Settings view for the Hivecrew REST API server
struct APISettingsView: View {
    
    // MARK: - State
    
    @AppStorage("apiServerEnabled") private var apiServerEnabled = false
    @AppStorage("apiServerPort") private var apiServerPort = 5482
    @AppStorage("apiMaxFileSize") private var apiMaxFileSize = 100 // MB
    @AppStorage("apiMaxTotalUploadSize") private var apiMaxTotalUploadSize = 500 // MB
    
    private var serverStatus: APIServerStatus { APIServerStatus.shared }
    
    @State private var apiKey: String = ""
    @State private var showAPIKey = false
    @State private var showRegenerateConfirmation = false
    @State private var copyFeedback = false
    @State private var restartTask: Task<Void, Never>?
    
    // Tips
    private let apiIntegrationTip = APIIntegrationTip()
    
    // MARK: - Body
    
    var body: some View {
        Form {
            // Server Section
            Section {
                Toggle("Enable API Server", isOn: $apiServerEnabled)
                    .onChange(of: apiServerEnabled) { _, newValue in
                        if newValue {
                            APIServerManager.shared.startIfEnabled()
                        } else {
                            APIServerManager.shared.stop()
                        }
                    }
                    .popoverTip(apiIntegrationTip, arrowEdge: .trailing)
                
                HStack {
                    Text("Port")
                    Spacer()
                    TextField("", value: $apiServerPort, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                        .onChange(of: apiServerPort) { _, _ in
                            if apiServerEnabled {
                                restartServerDebounced()
                            }
                        }
                }
                
                if apiServerEnabled {
                    HStack {
                        Text("Status")
                        Spacer()
                        HStack(spacing: 6) {
                            Circle()
                                .fill(serverStatus.state.statusColor)
                                .frame(width: 8, height: 8)
                            Text(serverStatus.state.statusText)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    if serverStatus.state.isRunning {
                        HStack {
                            Text("Base URL")
                            Spacer()
                            Text(baseURL)
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(baseURL, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help("Copy base URL")
                        }
                        
                        HStack {
                            Text("Web UI URL")
                            Spacer()
                            Text(webUiURL)
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(webUiURL, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help("Copy Web UI URL")
                        }
                    }
                }
            } header: {
                Text("Server")
            }
            
            // Authentication Section
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("API Key")
                        Spacer()
                        if copyFeedback {
                            Text("Copied!")
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    }
                    
                    HStack {
                        if showAPIKey {
                            Text(apiKey.isEmpty ? "Not generated" : apiKey)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        } else {
                            Text(apiKey.isEmpty ? "Not generated" : maskAPIKey(apiKey))
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        Button {
                            showAPIKey.toggle()
                        } label: {
                            Image(systemName: showAPIKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(showAPIKey ? "Hide API key" : "Show API key")
                        
                        Button {
                            copyAPIKeyToClipboard()
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .disabled(apiKey.isEmpty)
                        .help("Copy API key to clipboard")
                    }
                    
                    HStack {
                        if apiKey.isEmpty {
                            Button("Generate API Key") {
                                generateAPIKey()
                            }
                        } else {
                            Button("Regenerate") {
                                showRegenerateConfirmation = true
                            }
                            .foregroundColor(.orange)
                        }
                    }
                }
            } header: {
                Text("Authentication")
            }
            
            // File Upload Limits Section
            Section {
                HStack {
                    Text("Max file size")
                    Spacer()
                    TextField("", value: $apiMaxFileSize, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                    Text("MB")
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Text("Max total upload per task")
                    Spacer()
                    TextField("", value: $apiMaxTotalUploadSize, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                    Text("MB")
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("File Upload Limits")
            }
            
            // Usage Section
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Example: Create a task")
                        .font(.headline)
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(exampleCurlCommand)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .background(Color(NSColor.textBackgroundColor))
                            .cornerRadius(4)
                    }
                    
                    Button("Copy Example") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(exampleCurlCommand, forType: .string)
                    }
                }
            } header: {
                Text("Usage")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            loadAPIKey()
            // Refresh server status to sync with actual state
            APIServerManager.shared.refreshStatus()
            // Track API settings opened for tips
            TipStore.shared.donateAPISettingsOpened()
        }
        .alert("Regenerate API Key?", isPresented: $showRegenerateConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Regenerate", role: .destructive) {
                regenerateAPIKey()
            }
        } message: {
            Text("This will invalidate the current API key. Any applications using the old key will stop working.")
        }
    }
    
    // MARK: - Helpers
    
    private var baseURL: String {
        let port = serverStatus.actualPort ?? apiServerPort
        return "http://localhost:\(port)/api/v1"
    }
    
    private var webUiURL: String {
        let port = serverStatus.actualPort ?? apiServerPort
        return "http://localhost:\(port)/web"
    }
    
    private var exampleCurlCommand: String {
        return """
        curl -X POST http://localhost:\(apiServerPort)/api/v1/tasks \\
          -H "Authorization: Bearer $HIVECREW_API_KEY" \\
          -H "Content-Type: application/json" \\
          -d '{"description": "Open Safari", "providerName": "OpenRouter", "modelId": "anthropic/claude-sonnet-4.5"}'
        """
    }
    
    private func maskAPIKey(_ key: String) -> String {
        guard key.count > 8 else { return String(repeating: "•", count: key.count) }
        let prefix = String(key.prefix(4))
        let suffix = String(key.suffix(4))
        let middle = String(repeating: "•", count: min(20, key.count - 8))
        return prefix + middle + suffix
    }
    
    private func loadAPIKey() {
        apiKey = APIKeyManager.retrieveAPIKey() ?? ""
    }
    
    private func generateAPIKey() {
        if let key = APIKeyManager.generateAndStoreAPIKey() {
            apiKey = key
            showAPIKey = true
            if apiServerEnabled {
                APIServerManager.shared.restart()
            }
        }
    }
    
    private func regenerateAPIKey() {
        if let key = APIKeyManager.regenerateAPIKey() {
            apiKey = key
            showAPIKey = true
            if apiServerEnabled {
                APIServerManager.shared.restart()
            }
        }
    }
    
    /// Debounced restart to avoid multiple restarts during rapid changes
    private func restartServerDebounced() {
        restartTask?.cancel()
        restartTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            if !Task.isCancelled {
                await MainActor.run {
                    APIServerManager.shared.restart()
                }
            }
        }
    }
    
    private func copyAPIKeyToClipboard() {
        guard !apiKey.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(apiKey, forType: .string)
        
        copyFeedback = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copyFeedback = false
        }
    }
}

#Preview {
    APISettingsView()
        .frame(width: 550, height: 500)
}
