//
//  ProviderEditSheet.swift
//  Hivecrew
//
//  Sheet view for adding and editing LLM providers
//

import SwiftUI
import SwiftData

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
                    
                    Text("Leave empty to use the default OpenAI API endpoint. For other providers, enter the full API base URL.")
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
        !displayName.isEmpty
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
