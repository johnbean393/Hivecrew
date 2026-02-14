//
//  OnboardingProviderStep.swift
//  Hivecrew
//
//  LLM Provider setup step of the onboarding wizard
//

import SwiftUI
import SwiftData
import HivecrewLLM

/// LLM Provider configuration step
struct OnboardingProviderStep: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LLMProviderRecord.displayName) private var providers: [LLMProviderRecord]
    
    @Binding var isConfigured: Bool
    
    @State private var displayName: String = "OpenRouter"
    @State private var baseURL: String = ""
    @State private var apiKey: String = ""
    @State private var isTesting = false
    @State private var testResult: ConnectionTestResult?
    @State private var hasSaved = false
    
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
                    HStack {
                        TextField("Leave empty for OpenRouter default", text: $baseURL)
                            .textFieldStyle(.roundedBorder)
                        ProviderURLPickerMenu(baseURL: $baseURL)
                    }
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
                    ConnectionTestResultView(result: result, style: .compact)
                }
                
                Spacer()
                
                Button("Save Provider") {
                    saveProvider()
                }
                .buttonStyle(.borderedProminent)
                .disabled(displayName.isEmpty)
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
            let result = await ProviderConnectionTester.test(
                baseURL: baseURL,
                apiKey: apiKey
            )
            await MainActor.run {
                testResult = result
                isTesting = false
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

/// Worker model configuration step shown during onboarding.
struct OnboardingWorkerModelStep: View {
    @Query(sort: \LLMProviderRecord.displayName) private var providers: [LLMProviderRecord]
    @Binding var isConfigured: Bool

    @AppStorage("workerModelProviderId") private var workerModelProviderId: String?
    @AppStorage("workerModelId") private var workerModelId: String?

    @State private var availableModels: [LLMProviderModel] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var selectedProvider: LLMProviderRecord? {
        guard let workerModelProviderId, !workerModelProviderId.isEmpty else { return nil }
        return providers.first(where: { $0.id == workerModelProviderId })
    }

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Image(systemName: "bolt.circle")
                    .font(.system(size: 48))
                    .foregroundStyle(.orange)

                Text("Configure Worker Model")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("The worker model is required and powers fast background reasoning for suggestions, titles, and lightweight extraction tasks.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 20)

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Worker Provider")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker(
                        "Worker Provider",
                        selection: Binding(
                            get: { workerModelProviderId ?? "" },
                            set: { newValue in
                                let normalized = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                workerModelProviderId = normalized.isEmpty ? nil : normalized
                                workerModelId = nil
                                availableModels = []
                                errorMessage = nil
                                loadModelsForSelectedProvider()
                                refreshConfiguredState()
                            }
                        )
                    ) {
                        ForEach(providers) { provider in
                            Text(provider.displayName).tag(provider.id)
                        }
                    }
                    .pickerStyle(.menu)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Worker Model")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if isLoading {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("Loading available models...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if let errorMessage {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                            Button("Retry Model Load") {
                                loadModelsForSelectedProvider()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    } else if availableModels.isEmpty {
                        Text("No models available for this provider.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker(
                            "Worker Model",
                            selection: Binding(
                                get: { workerModelId ?? "" },
                                set: { newValue in
                                    let normalized = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                    workerModelId = normalized.isEmpty ? nil : normalized
                                    refreshConfiguredState()
                                }
                            )
                        ) {
                            ForEach(availableModels) { model in
                                Text(model.displayName).tag(model.id)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }

                Text("Choose a low-latency worker model. You can update this later in Settings → Providers.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 60)

            Spacer()

            if isConfigured {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Worker model configured")
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 8)
            } else {
                Text("Select both a worker provider and worker model to continue.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.bottom, 8)
            }
        }
        .padding()
        .onAppear {
            ensureProviderSelection()
            loadModelsForSelectedProvider()
            refreshConfiguredState()
        }
        .onChange(of: providers.count) { _, _ in
            ensureProviderSelection()
            loadModelsForSelectedProvider()
            refreshConfiguredState()
        }
    }

    private func ensureProviderSelection() {
        guard !providers.isEmpty else {
            workerModelProviderId = nil
            workerModelId = nil
            return
        }

        if let existing = workerModelProviderId,
           providers.contains(where: { $0.id == existing }) {
            return
        }

        workerModelProviderId = providers.first(where: { $0.isDefault })?.id ?? providers.first?.id
        workerModelId = nil
    }

    private func refreshConfiguredState() {
        let hasProvider = !(workerModelProviderId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasModel = !(workerModelId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        isConfigured = hasProvider && hasModel
    }

    private func loadModelsForSelectedProvider() {
        guard let provider = selectedProvider else {
            availableModels = []
            errorMessage = "Select a provider to load models."
            refreshConfiguredState()
            return
        }
        guard let apiKey = provider.retrieveAPIKey(), !apiKey.isEmpty else {
            availableModels = []
            errorMessage = "This provider has no API key configured."
            refreshConfiguredState()
            return
        }

        isLoading = true
        errorMessage = nil

        Task {
            do {
                let config = LLMConfiguration(
                    displayName: provider.displayName,
                    baseURL: provider.parsedBaseURL,
                    apiKey: apiKey,
                    model: "moonshotai/kimi-k2.5",
                    organizationId: provider.organizationId,
                    timeoutInterval: provider.timeoutInterval
                )
                let client = LLMService.shared.createClient(from: config)
                let models = try await client.listModelsDetailed()

                await MainActor.run {
                    availableModels = models
                    isLoading = false
                    if let existing = workerModelId, models.contains(where: { $0.id == existing }) {
                        refreshConfiguredState()
                    } else if let firstModel = models.first {
                        workerModelId = firstModel.id
                        refreshConfiguredState()
                    } else {
                        workerModelId = nil
                        refreshConfiguredState()
                    }
                }
            } catch {
                await MainActor.run {
                    availableModels = []
                    isLoading = false
                    errorMessage = error.localizedDescription
                    workerModelId = nil
                    refreshConfiguredState()
                }
            }
        }
    }
}

#Preview {
    OnboardingProviderStep(isConfigured: .constant(false))
        .modelContainer(for: LLMProviderRecord.self, inMemory: true)
        .frame(width: 600, height: 450)
}
