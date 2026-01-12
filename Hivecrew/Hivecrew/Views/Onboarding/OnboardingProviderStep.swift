//
//  OnboardingProviderStep.swift
//  Hivecrew
//
//  LLM Provider setup step of the onboarding wizard
//

import SwiftUI
import SwiftData

/// LLM Provider configuration step
struct OnboardingProviderStep: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LLMProviderRecord.displayName) private var providers: [LLMProviderRecord]
    
    @Binding var isConfigured: Bool
    
    @State private var displayName: String = "OpenAI"
    @State private var baseURL: String = ""
    @State private var apiKey: String = ""
    @State private var isTesting = false
    @State private var testResult: TestResult?
    @State private var hasSaved = false
    
    enum TestResult {
        case success
        case failure(String)
    }
    
    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 48))
                    .foregroundStyle(.blue)
                
                Text("Configure LLM Provider")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text("Connect to an OpenAI-compatible API to power your agents")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 20)
            
            // Form
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Provider Name")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("e.g., OpenAI, Claude, Local LLM", text: $displayName)
                        .textFieldStyle(.roundedBorder)
                }
                
                VStack(alignment: .leading, spacing: 6) {
                    Text("API Key")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SecureField("sk-...", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                }
                
                VStack(alignment: .leading, spacing: 6) {
                    Text("Base URL (optional)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Leave empty for OpenAI default", text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                    Text("For custom endpoints like Azure, Anthropic, or local LLMs")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 60)
            
            // Test & Save
            HStack(spacing: 16) {
                Button {
                    testConnection()
                } label: {
                    HStack(spacing: 6) {
                        if isTesting {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "network")
                        }
                        Text("Test Connection")
                    }
                }
                .disabled(apiKey.isEmpty || isTesting)
                
                if let result = testResult {
                    switch result {
                    case .success:
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Connected")
                                .foregroundStyle(.green)
                        }
                        .font(.callout)
                    case .failure(let message):
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                            Text(message)
                                .foregroundStyle(.red)
                                .lineLimit(1)
                        }
                        .font(.callout)
                    }
                }
                
                Spacer()
                
                Button("Save Provider") {
                    saveProvider()
                }
                .buttonStyle(.borderedProminent)
                .disabled(displayName.isEmpty || apiKey.isEmpty)
            }
            .padding(.horizontal, 60)
            
            Spacer()
            
            // Status
            if hasSaved || !providers.isEmpty {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Provider configured")
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 8)
            }
        }
        .padding()
        .onChange(of: providers.count) { _, newCount in
            isConfigured = newCount > 0
        }
        .onAppear {
            isConfigured = !providers.isEmpty
        }
    }
    
    private func testConnection() {
        isTesting = true
        testResult = nil
        
        Task {
            do {
                let apiURL: URL
                if let customBase = baseURL.isEmpty ? nil : URL(string: baseURL) {
                    apiURL = customBase.appendingPathComponent("models")
                } else {
                    apiURL = URL(string: "https://api.openai.com/v1/models")!
                }
                
                var request = URLRequest(url: apiURL)
                request.httpMethod = "GET"
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                request.timeoutInterval = 15
                
                let (_, response) = try await URLSession.shared.data(for: request)
                
                await MainActor.run {
                    if let httpResponse = response as? HTTPURLResponse {
                        if httpResponse.statusCode == 200 {
                            testResult = .success
                        } else if httpResponse.statusCode == 401 {
                            testResult = .failure("Invalid API key")
                        } else {
                            testResult = .failure("HTTP \(httpResponse.statusCode)")
                        }
                    }
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
    
    private func saveProvider() {
        let provider = LLMProviderRecord(
            displayName: displayName,
            baseURL: baseURL.isEmpty ? nil : baseURL,
            organizationId: nil,
            isDefault: providers.isEmpty, // First provider is default
            timeoutInterval: 120
        )
        provider.storeAPIKey(apiKey)
        modelContext.insert(provider)
        
        hasSaved = true
        isConfigured = true
        
        // Clear form for potential additional providers
        displayName = ""
        apiKey = ""
        baseURL = ""
        testResult = nil
    }
}

#Preview {
    OnboardingProviderStep(isConfigured: .constant(false))
        .modelContainer(for: LLMProviderRecord.self, inMemory: true)
        .frame(width: 600, height: 450)
}
