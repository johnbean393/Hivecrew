//
//  ProvidersSettingsView.swift
//  Hivecrew
//
//  LLM Providers settings tab with full provider management
//

import SwiftUI
import SwiftData

/// LLM Providers settings tab
struct ProvidersSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LLMProviderRecord.displayName) private var providers: [LLMProviderRecord]
    
    @State private var showingAddSheet = false
    @State private var editingProvider: LLMProviderRecord?
    @State private var providerToDelete: LLMProviderRecord?
    @State private var showingDeleteConfirmation = false
    
    @AppStorage("workerModelProviderId") private var workerModelProviderId: String?
    @AppStorage("workerModelId") private var workerModelId: String?
    
    var body: some View {
        Form {
            providersListSection
            workerModelSection
        }
        .formStyle(.grouped)
        .padding()
        .sheet(isPresented: $showingAddSheet) {
            ProviderEditSheet(provider: nil)
        }
        .sheet(item: $editingProvider) { provider in
            ProviderEditSheet(provider: provider)
        }
        .confirmationDialog(
            "Delete Provider",
            isPresented: $showingDeleteConfirmation,
            presenting: providerToDelete
        ) { provider in
            Button("Delete", role: .destructive) {
                deleteProvider(provider)
            }
            Button("Cancel", role: .cancel) {}
        } message: { provider in
            Text("Are you sure you want to delete \"\(provider.displayName)\"? This will also remove the API key from your keychain.")
        }
    }
    
    // MARK: - Sections
    
    private var providersListSection: some View {
        Section("Providers") {
            if providers.isEmpty {
                ContentUnavailableView {
                    Label("No Providers", systemImage: "cpu")
                } description: {
                    Text("Add an LLM provider to get started with agent tasks.")
                } actions: {
                    Button("Add Provider") {
                        showingAddSheet = true
                    }
                }
                .frame(height: 150)
            } else {
                ForEach(providers) { provider in
                    ProviderRow(
                        provider: provider,
                        onEdit: { editingProvider = provider },
                        onDelete: {
                            providerToDelete = provider
                            showingDeleteConfirmation = true
                        },
                        onSetDefault: { setAsDefault(provider) }
                    )
                }
                
                Button {
                    showingAddSheet = true
                } label: {
                    HStack {
                        Image(systemName: "plus.circle")
                        Text("Add Provider")
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .padding(.vertical, 4)
            }
        }
    }
    
    private var workerModelSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text("Worker Model")
                    .font(.headline)
                
                Text("Select a cheaper/faster model for simple tasks like title generation and webpage extraction. Leave unset to use the main model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                // Provider picker
                Picker("Provider", selection: $workerModelProviderId) {
                    Text("Use Main Model").tag(nil as String?)
                    ForEach(providers) { provider in
                        Text(provider.displayName).tag(provider.id as String?)
                    }
                }
                
                // Model input field (simple text field for model ID)
                if workerModelProviderId != nil {
                    HStack {
                        Text("Model ID:")
                        TextField("", text: Binding(
                            get: { workerModelId ?? "" },
                            set: { workerModelId = $0.isEmpty ? nil : $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }
                    
                    Text("Enter the model ID. The worker model is used for simple tasks like title generation and webpage information extraction.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }
    
    // MARK: - Actions
    
    private func deleteProvider(_ provider: LLMProviderRecord) {
        // Delete API key from keychain
        provider.deleteAPIKey()
        
        // Delete from SwiftData
        modelContext.delete(provider)
        
        // If we deleted the default, set a new one
        if provider.isDefault, let firstRemaining = providers.first(where: { $0.id != provider.id }) {
            firstRemaining.isDefault = true
        }
    }
    
    private func setAsDefault(_ provider: LLMProviderRecord) {
        // Clear default from all providers
        for p in providers {
            p.isDefault = false
        }
        // Set new default
        provider.isDefault = true
    }
}

// MARK: - Provider Row

struct ProviderRow: View {
    let provider: LLMProviderRecord
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onSetDefault: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // Provider icon
            Image(systemName: providerIcon)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 32)
            
            // Provider info
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(provider.displayName)
                        .fontWeight(.medium)
                    
                    if provider.isDefault {
                        Text("Default")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.15))
                            .foregroundStyle(.blue)
                            .clipShape(Capsule())
                    }
                }
                
                if let baseURL = provider.baseURL {
                    Text(baseURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("OpenAI API")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            // API Key status
            HStack(spacing: 4) {
                Image(systemName: provider.hasAPIKey ? "key.fill" : "key")
                    .foregroundStyle(provider.hasAPIKey ? .green : .orange)
                Text(provider.hasAPIKey ? "Configured" : "No Key")
                    .font(.caption)
                    .foregroundStyle(provider.hasAPIKey ? Color.secondary : Color.orange)
            }
            
            // Actions menu
            Menu {
                Button("Edit") {
                    onEdit()
                }
                
                if !provider.isDefault {
                    Button("Set as Default") {
                        onSetDefault()
                    }
                }
                
                Divider()
                
                Button("Delete", role: .destructive) {
                    onDelete()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
    }
    
    private var providerIcon: String {
        if provider.baseURL?.contains("azure") == true {
            return "cloud.fill"
        } else if provider.baseURL?.contains("localhost") == true {
            return "desktopcomputer"
        } else if provider.baseURL != nil {
            return "server.rack"
        } else {
            return "cpu"
        }
    }
}

// MARK: - Provider Edit Sheet

struct ProviderEditSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \LLMProviderRecord.displayName) private var allProviders: [LLMProviderRecord]
    
    let provider: LLMProviderRecord?
    
    @State private var displayName: String = ""
    @State private var baseURL: String = ""
    @State private var apiKey: String = ""
    @State private var organizationId: String = ""
    @State private var isDefault: Bool = false
    @State private var timeoutInterval: Double = 120.0
    
    @State private var isTesting = false
    @State private var testResult: TestResult?
    
    enum TestResult {
        case success
        case failure(String)
    }
    
    var isEditing: Bool {
        provider != nil
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape)
                
                Spacer()
                
                Text(isEditing ? "Edit Provider" : "Add Provider")
                    .fontWeight(.semibold)
                
                Spacer()
                
                Button("Save") {
                    save()
                }
                .keyboardShortcut(.return)
                .disabled(!isValid)
            }
            .padding()
            
            Divider()
            
            // Form
            Form {
                Section("Provider Details") {
                    TextField("Display Name", text: $displayName)
                        .textFieldStyle(.roundedBorder)
                    
                    TextField("Base URL (optional)", text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.URL)
                    
                    Text("Leave empty to use the default OpenAI API endpoint. For other providers, enter the full API base URL. Models will be fetched automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Section("Authentication") {
                    SecureField("API Key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                    
                    if isEditing && apiKey.isEmpty {
                        Text("Leave empty to keep the existing API key.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    TextField("Organization ID (optional)", text: $organizationId)
                        .textFieldStyle(.roundedBorder)
                }
                
                Section("Options") {
                    Toggle("Set as Default Provider", isOn: $isDefault)
                    
                    HStack {
                        Text("Timeout")
                        Spacer()
                        TextField("", value: $timeoutInterval, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        Text("seconds")
                            .foregroundStyle(.secondary)
                    }
                }
                
                Section("Test Connection") {
                    HStack {
                        Button {
                            testConnection()
                        } label: {
                            HStack {
                                if isTesting {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                        .frame(width: 16, height: 16)
                                } else {
                                    Image(systemName: "network")
                                }
                                Text("Test Connection")
                            }
                        }
                        .disabled(currentAPIKey.isEmpty || isTesting)
                        
                        Spacer()
                        
                        if let result = testResult {
                            switch result {
                            case .success:
                                HStack {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                    Text("Connection successful")
                                        .foregroundStyle(.secondary)
                                }
                            case .failure(let message):
                                HStack {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.red)
                                    Text(message)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 500, height: 520)
        .onAppear {
            loadProvider()
        }
    }
    
    private var isValid: Bool {
        !displayName.isEmpty && (!apiKey.isEmpty || isEditing)
    }
    
    /// The API key to use for testing - either the newly entered one or the existing one
    private var currentAPIKey: String {
        if !apiKey.isEmpty {
            return apiKey
        }
        return provider?.retrieveAPIKey() ?? ""
    }
    
    private func loadProvider() {
        guard let provider = provider else { return }
        
        displayName = provider.displayName
        baseURL = provider.baseURL ?? ""
        organizationId = provider.organizationId ?? ""
        isDefault = provider.isDefault
        timeoutInterval = provider.timeoutInterval
        // Don't load API key - it's stored in keychain
    }
    
    private func save() {
        if let existingProvider = provider {
            // Update existing
            existingProvider.displayName = displayName
            existingProvider.baseURL = baseURL.isEmpty ? nil : baseURL
            existingProvider.organizationId = organizationId.isEmpty ? nil : organizationId
            existingProvider.timeoutInterval = timeoutInterval
            
            // Update API key if provided
            if !apiKey.isEmpty {
                existingProvider.storeAPIKey(apiKey)
            }
            
            // Handle default flag
            if isDefault {
                setAsDefault(existingProvider)
            }
        } else {
            // Create new
            let newProvider = LLMProviderRecord(
                displayName: displayName,
                baseURL: baseURL.isEmpty ? nil : baseURL,
                organizationId: organizationId.isEmpty ? nil : organizationId,
                isDefault: isDefault,
                timeoutInterval: timeoutInterval
            )
            
            // Store API key
            newProvider.storeAPIKey(apiKey)
            
            // Handle default flag
            if isDefault {
                setAsDefault(newProvider)
            }
            
            modelContext.insert(newProvider)
        }
        
        dismiss()
    }
    
    private func setAsDefault(_ provider: LLMProviderRecord) {
        // Clear default from all other providers
        for p in allProviders where p.id != provider.id {
            p.isDefault = false
        }
        provider.isDefault = true
    }
    
    private func testConnection() {
        isTesting = true
        testResult = nil
        
        Task {
            do {
                // Build the API URL
                let apiURL: URL
                if let customBase = baseURL.isEmpty ? nil : URL(string: baseURL) {
                    apiURL = customBase.appendingPathComponent("models")
                } else {
                    apiURL = URL(string: "https://api.openai.com/v1/models")!
                }
                
                // Create a simple test request to the models endpoint
                var request = URLRequest(url: apiURL)
                request.httpMethod = "GET"
                request.setValue("Bearer \(currentAPIKey)", forHTTPHeaderField: "Authorization")
                if !organizationId.isEmpty {
                    request.setValue(organizationId, forHTTPHeaderField: "OpenAI-Organization")
                }
                request.timeoutInterval = min(timeoutInterval, 30)
                
                let (_, response) = try await URLSession.shared.data(for: request)
                
                if let httpResponse = response as? HTTPURLResponse {
                    await MainActor.run {
                        if httpResponse.statusCode == 200 {
                            testResult = .success
                        } else if httpResponse.statusCode == 401 {
                            testResult = .failure("Invalid API key")
                        } else if httpResponse.statusCode == 403 {
                            testResult = .failure("Access denied")
                        } else {
                            testResult = .failure("HTTP \(httpResponse.statusCode)")
                        }
                        isTesting = false
                    }
                }
            } catch {
                await MainActor.run {
                    testResult = .failure(error.localizedDescription)
                    isTesting = false
                }
            }
        }
    }
}

#Preview {
    ProvidersSettingsView()
        .modelContainer(for: LLMProviderRecord.self, inMemory: true)
}
