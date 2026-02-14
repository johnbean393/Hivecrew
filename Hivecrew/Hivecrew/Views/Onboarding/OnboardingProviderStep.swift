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

    @AppStorage("lastSelectedProviderId") private var mainModelProviderId: String = ""
    @AppStorage("lastSelectedModelId") private var mainModelId: String = ""
    @AppStorage("workerModelProviderId") private var workerModelProviderId: String?
    @AppStorage("workerModelId") private var workerModelId: String?

    @State private var availableMainModels: [LLMProviderModel] = []
    @State private var isLoadingMainModels = false
    @State private var mainModelErrorMessage: String?

    @State private var availableWorkerModels: [LLMProviderModel] = []
    @State private var isLoadingWorkerModels = false
    @State private var workerModelErrorMessage: String?

    private enum ModelLoadError: LocalizedError {
        case missingAPIKey

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "This provider has no API key configured."
            }
        }
    }

    private var selectedMainProvider: LLMProviderRecord? {
        let normalized = mainModelProviderId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return providers.first(where: { $0.id == normalized })
    }

    private var selectedWorkerProvider: LLMProviderRecord? {
        guard let workerModelProviderId else { return nil }
        let normalized = workerModelProviderId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return providers.first(where: { $0.id == normalized })
    }

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Image(systemName: "bolt.circle")
                    .font(.system(size: 48))
                    .foregroundStyle(.orange)

                Text("Configure Main & Worker Models")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Choose both the main chat model and worker model used for lightweight background tasks.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 20)

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Main Provider")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker(
                        "Main Provider",
                        selection: Binding(
                            get: { mainModelProviderId },
                            set: { newValue in
                                let normalized = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                mainModelProviderId = normalized
                                mainModelId = ""
                                availableMainModels = []
                                mainModelErrorMessage = nil
                                loadMainModelsForSelectedProvider()
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
                    Text("Main Model")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if isLoadingMainModels {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("Loading available models...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if let mainModelErrorMessage {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(mainModelErrorMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                            Button("Retry Model Load") {
                                loadMainModelsForSelectedProvider()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    } else if availableMainModels.isEmpty {
                        Text("No models available for this provider.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker(
                            "Main Model",
                            selection: Binding(
                                get: { mainModelId },
                                set: { newValue in
                                    mainModelId = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                    refreshConfiguredState()
                                }
                            )
                        ) {
                            ForEach(availableMainModels) { model in
                                Text(model.displayName).tag(model.id)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }

                Divider()

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
                                availableWorkerModels = []
                                workerModelErrorMessage = nil
                                loadWorkerModelsForSelectedProvider()
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

                    if isLoadingWorkerModels {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("Loading available models...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if let workerModelErrorMessage {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(workerModelErrorMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                            Button("Retry Model Load") {
                                loadWorkerModelsForSelectedProvider()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    } else if availableWorkerModels.isEmpty {
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
                            ForEach(availableWorkerModels) { model in
                                Text(model.displayName).tag(model.id)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }

                Text("Choose a capable main model and a low-latency worker model. You can update both later in Settings.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 60)

            Spacer()

            if isConfigured {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Main and worker models configured")
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 8)
            } else {
                Text("Select main and worker providers + models to continue.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.bottom, 8)
            }
        }
        .padding()
        .onAppear {
            ensureProviderSelection()
            loadMainModelsForSelectedProvider()
            loadWorkerModelsForSelectedProvider()
            refreshConfiguredState()
        }
        .onChange(of: providers.count) { _, _ in
            ensureProviderSelection()
            loadMainModelsForSelectedProvider()
            loadWorkerModelsForSelectedProvider()
            refreshConfiguredState()
        }
    }

    private func ensureProviderSelection() {
        guard !providers.isEmpty else {
            mainModelProviderId = ""
            mainModelId = ""
            workerModelProviderId = nil
            workerModelId = nil
            availableMainModels = []
            availableWorkerModels = []
            return
        }

        let defaultProviderId = providers.first(where: { $0.isDefault })?.id ?? providers.first?.id ?? ""

        let normalizedMainProviderId = mainModelProviderId.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedMainProviderId.isEmpty || !providers.contains(where: { $0.id == normalizedMainProviderId }) {
            mainModelProviderId = defaultProviderId
            mainModelId = ""
        }

        let normalizedWorkerProviderId = workerModelProviderId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if normalizedWorkerProviderId.isEmpty || !providers.contains(where: { $0.id == normalizedWorkerProviderId }) {
            workerModelProviderId = defaultProviderId.isEmpty ? nil : defaultProviderId
            workerModelId = nil
        }
    }

    private func refreshConfiguredState() {
        let hasMainProvider = !mainModelProviderId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasMainModel = !mainModelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasWorkerProvider = !(workerModelProviderId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasWorkerModel = !(workerModelId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        isConfigured = hasMainProvider && hasMainModel && hasWorkerProvider && hasWorkerModel
    }

    private func loadMainModelsForSelectedProvider() {
        guard let provider = selectedMainProvider else {
            availableMainModels = []
            mainModelErrorMessage = "Select a provider to load models."
            mainModelId = ""
            refreshConfiguredState()
            return
        }

        isLoadingMainModels = true
        mainModelErrorMessage = nil

        Task {
            do {
                let models = try await fetchModels(for: provider)

                await MainActor.run {
                    availableMainModels = models
                    isLoadingMainModels = false
                    if models.contains(where: { $0.id == mainModelId }) {
                        refreshConfiguredState()
                    } else if let firstModel = models.first {
                        mainModelId = firstModel.id
                        refreshConfiguredState()
                    } else {
                        mainModelId = ""
                        refreshConfiguredState()
                    }
                }
            } catch {
                await MainActor.run {
                    availableMainModels = []
                    isLoadingMainModels = false
                    mainModelErrorMessage = error.localizedDescription
                    mainModelId = ""
                    refreshConfiguredState()
                }
            }
        }
    }

    private func loadWorkerModelsForSelectedProvider() {
        guard let provider = selectedWorkerProvider else {
            availableWorkerModels = []
            workerModelErrorMessage = "Select a provider to load models."
            workerModelId = nil
            refreshConfiguredState()
            return
        }

        isLoadingWorkerModels = true
        workerModelErrorMessage = nil

        Task {
            do {
                let models = try await fetchModels(for: provider)

                await MainActor.run {
                    availableWorkerModels = models
                    isLoadingWorkerModels = false
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
                    availableWorkerModels = []
                    isLoadingWorkerModels = false
                    workerModelErrorMessage = error.localizedDescription
                    workerModelId = nil
                    refreshConfiguredState()
                }
            }
        }
    }

    private func fetchModels(for provider: LLMProviderRecord) async throws -> [LLMProviderModel] {
        guard let apiKey = provider.retrieveAPIKey(), !apiKey.isEmpty else {
            throw ModelLoadError.missingAPIKey
        }

        let config = LLMConfiguration(
            displayName: provider.displayName,
            baseURL: provider.parsedBaseURL,
            apiKey: apiKey,
            model: "moonshotai/kimi-k2.5",
            organizationId: provider.organizationId,
            timeoutInterval: provider.timeoutInterval
        )
        let client = LLMService.shared.createClient(from: config)
        return try await client.listModelsDetailed()
    }
}

#Preview {
    OnboardingProviderStep(isConfigured: .constant(false))
        .modelContainer(for: LLMProviderRecord.self, inMemory: true)
        .frame(width: 720, height: 450)
}
