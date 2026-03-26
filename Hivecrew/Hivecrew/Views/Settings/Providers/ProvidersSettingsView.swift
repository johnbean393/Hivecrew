//
//  ProvidersSettingsView.swift
//  Hivecrew
//
//  LLM Providers settings tab with full provider management
//

import AppKit
import SwiftUI
import SwiftData
import TipKit
import HivecrewLLM

/// LLM Providers settings tab
struct ProvidersSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LLMProviderRecord.displayName) private var providers: [LLMProviderRecord]
    
    @State private var addProviderPreset: AddProviderPreset?
    @State private var editingProvider: LLMProviderRecord?
    @State private var providerToDelete: LLMProviderRecord?
    @State private var showingDeleteConfirmation = false
    @State private var availableWorkerModels: [LLMProviderModel] = []
    @State private var isLoadingWorkerModels = false
    @State private var workerModelErrorMessage: String?
    
    @AppStorage("workerModelProviderId") private var workerModelProviderId: String?
    @AppStorage("workerModelId") private var workerModelId: String?
    @AppStorage("subagentsUseWorkerModel") private var subagentsUseWorkerModel = true
    
    // Tips
    private let configureProvidersTip = ConfigureProvidersTip()

    private enum AddProviderPreset: String, Identifiable {
        case chatCompletions
        case responses
        case chatGPTOAuth

        var id: String { rawValue }

        var backendMode: LLMBackendMode {
            switch self {
            case .chatCompletions:
                return .chatCompletions
            case .responses:
                return .responses
            case .chatGPTOAuth:
                return .codexOAuth
            }
        }
    }

    private enum ModelLoadError: LocalizedError {
        case missingAPIKey

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "This provider has no API key configured."
            }
        }
    }

    private var selectedWorkerProvider: LLMProviderRecord? {
        guard let workerModelProviderId else { return nil }
        let normalized = workerModelProviderId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return providers.first(where: { $0.id == normalized })
    }

    private var selectedWorkerModel: LLMProviderModel? {
        guard let workerModelId else { return nil }
        let normalized = workerModelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return availableWorkerModels.first(where: { $0.id == normalized })
    }
    
    var body: some View {
        Form {
            providersListSection
            workerModelSection
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            TipStore.shared.updateProviderCount(providers.count)
            ensureWorkerModelSelection()
            loadWorkerModelsForSelectedProvider()
        }
        .onChange(of: providers.count) { _, newCount in
            TipStore.shared.updateProviderCount(newCount)
            ensureWorkerModelSelection()
            loadWorkerModelsForSelectedProvider()
        }
        .sheet(item: $addProviderPreset) { preset in
            ProviderEditSheet(provider: nil, initialBackendMode: preset.backendMode)
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
            Text("Are you sure you want to delete \"\(provider.displayLabel)\"? This will also remove the API key from your keychain.")
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
                    addProviderMenuLabel
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
                
                addProviderMenuLabel
                    .padding(.vertical, 4)
                    .popoverTip(configureProvidersTip, arrowEdge: .trailing)
            }
        }
    }

    private var addProviderMenuLabel: some View {
        Menu {
            Button("Responses API") {
                addProviderPreset = .responses
            }

            Button("Chat Completions") {
                addProviderPreset = .chatCompletions
            }

            Button {
                addProviderPreset = .chatGPTOAuth
            } label: {
                Label {
                    Text("Sign in with ChatGPT")
                } icon: {
                    openAILogoMenuImage
                }
            }
        } label: {
            HStack {
                Image(systemName: "plus.circle")
                Text("Add Provider")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.blue)
    }

    private var openAILogoMenuImage: Image {
        guard let sourceImage = NSImage(named: "OpenAILogo"),
              let resizedImage = sourceImage.copy() as? NSImage else {
            return Image("OpenAILogo").renderingMode(.template)
        }

        resizedImage.size = NSSize(width: 14, height: 14)
        resizedImage.isTemplate = true
        return Image(nsImage: resizedImage)
    }
    
    private var workerModelSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text("Worker Model")
                    .font(.headline)
                
                Text("Worker model is required. It powers fast background tasks like title generation, retrieval guidance, and webpage extraction.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Use worker model for subagents by default", isOn: $subagentsUseWorkerModel)

                Text("When enabled, new subagent runs use the configured worker model instead of the main task model unless a flow overrides it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                VStack(alignment: .leading, spacing: 6) {
                    Text("Provider")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker(
                        "Provider",
                        selection: Binding(
                            get: { workerModelProviderId ?? "" },
                            set: { newValue in
                                let normalized = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                workerModelProviderId = normalized.isEmpty ? nil : normalized
                                workerModelId = nil
                                availableWorkerModels = []
                                workerModelErrorMessage = nil
                                loadWorkerModelsForSelectedProvider()
                            }
                        )
                    ) {
                        Text("Select Provider").tag("")
                        ForEach(providers) { provider in
                            Text(provider.displayLabel).tag(provider.id)
                        }
                    }
                    .pickerStyle(.menu)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Model")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if providers.isEmpty {
                        Text("Add a provider to choose a worker model.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if (workerModelProviderId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
                        Text("Select a provider to load models.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if isLoadingWorkerModels {
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
                            "Model",
                            selection: Binding(
                                get: { workerModelId ?? "" },
                                set: { newValue in
                                    let normalized = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                    workerModelId = normalized.isEmpty ? nil : normalized
                                }
                            )
                        ) {
                            ForEach(availableWorkerModels) { model in
                                Text(model.displayName).tag(model.id)
                            }
                        }
                        .pickerStyle(.menu)

                        if let selectedModel = selectedWorkerModel {
                            Text(selectedModel.id)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                        }
                    }

                    Text("Choose the model used for simple background tasks like title generation and webpage information extraction.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let selectedWorkerModel,
                       selectedWorkerModel.reasoningCapability.kind == .effort,
                       selectedWorkerModel.reasoningCapability.supportedEfforts.contains(where: {
                           $0.caseInsensitiveCompare("low") == .orderedSame
                       }) {
                        Text("This worker model supports `low` reasoning effort, which Hivecrew will use automatically for worker-model runs.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if (workerModelProviderId?.isEmpty ?? true) || (workerModelId?.isEmpty ?? true) {
                    Label("Worker provider and model are required.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
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

    private func ensureWorkerModelSelection() {
        guard !providers.isEmpty else {
            workerModelProviderId = nil
            workerModelId = nil
            availableWorkerModels = []
            workerModelErrorMessage = nil
            return
        }

        let defaultProviderId = providers.first(where: { $0.isDefault })?.id ?? providers.first?.id ?? ""
        let normalizedWorkerProviderId = workerModelProviderId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if normalizedWorkerProviderId.isEmpty || !providers.contains(where: { $0.id == normalizedWorkerProviderId }) {
            workerModelProviderId = defaultProviderId.isEmpty ? nil : defaultProviderId
            workerModelId = nil
        }
    }

    private func loadWorkerModelsForSelectedProvider() {
        guard let provider = selectedWorkerProvider else {
            availableWorkerModels = []
            workerModelErrorMessage = providers.isEmpty ? nil : "Select a provider to load models."
            workerModelId = nil
            isLoadingWorkerModels = false
            return
        }

        let requestProviderId = provider.id
        isLoadingWorkerModels = true
        workerModelErrorMessage = nil

        Task {
            do {
                let models = try await fetchModels(for: provider)

                await MainActor.run {
                    guard requestProviderId == workerModelProviderId else { return }
                    availableWorkerModels = models
                    isLoadingWorkerModels = false

                    if let existing = workerModelId, models.contains(where: { $0.id == existing }) {
                        return
                    }

                    workerModelId = models.first?.id
                }
            } catch {
                await MainActor.run {
                    guard requestProviderId == workerModelProviderId else { return }
                    availableWorkerModels = []
                    isLoadingWorkerModels = false
                    workerModelErrorMessage = error.localizedDescription
                    workerModelId = nil
                }
            }
        }
    }

    private func fetchModels(for provider: LLMProviderRecord) async throws -> [LLMProviderModel] {
        let apiKey: String
        if provider.authMode == .apiKey {
            guard let stored = provider.retrieveAPIKey(), !stored.isEmpty else {
                throw ModelLoadError.missingAPIKey
            }
            apiKey = stored
        } else {
            apiKey = ""
        }

        let config = provider.makeLLMConfiguration(
            model: provider.backendMode == .codexOAuth ? "gpt-5-codex" : "model-listing-placeholder",
            apiKey: apiKey
        )
        let client = LLMService.shared.createClient(from: config)
        return LLMProviderModel.sortByVersionDescending(try await client.listModelsDetailed())
    }
}

#Preview {
    ProvidersSettingsView()
        .modelContainer(for: LLMProviderRecord.self, inMemory: true)
}
