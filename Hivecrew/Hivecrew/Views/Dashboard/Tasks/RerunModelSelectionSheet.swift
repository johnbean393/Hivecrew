//
//  RerunModelSelectionSheet.swift
//  Hivecrew
//
//  Sheet for rerunning a task with a specific provider/model
//

import SwiftUI
import SwiftData
import HivecrewLLM

struct RerunModelSelectionSheet: View {
    let task: TaskRecord
    let onConfirm: (_ providerId: String, _ modelId: String) -> Void
    
    @Environment(\.dismiss) private var dismiss
    @Query private var providers: [LLMProviderRecord]
    
    @State private var selectedProviderId: String
    @State private var selectedModelId: String
    @State private var searchText: String = ""
    @State private var availableModels: [LLMProviderModel] = []
    @State private var isLoadingModels: Bool = false
    @State private var modelLoadError: String?
    
    init(task: TaskRecord, onConfirm: @escaping (_ providerId: String, _ modelId: String) -> Void) {
        self.task = task
        self.onConfirm = onConfirm
        self._selectedProviderId = State(initialValue: task.providerId)
        self._selectedModelId = State(initialValue: task.modelId)
    }
    
    private var selectedProvider: LLMProviderRecord? {
        providers.first(where: { $0.id == selectedProviderId })
    }
    
    private var trimmedProviderId: String {
        selectedProviderId.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private var trimmedModelId: String {
        selectedModelId.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private var canConfirm: Bool {
        !trimmedProviderId.isEmpty && !trimmedModelId.isEmpty
    }
    
    private var isOpenRouterProvider: Bool {
        guard let host = selectedProvider?.effectiveBaseURL.host?.lowercased() else {
            return false
        }
        return host.contains("openrouter.ai")
    }
    
    private var filteredModels: [LLMProviderModel] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return orderedModels
        }
        
        return orderedModels.filter { model in
            model.id.localizedCaseInsensitiveContains(query)
            || model.displayName.localizedCaseInsensitiveContains(query)
            || (model.description?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }
    
    private var orderedModels: [LLMProviderModel] {
        let selected = availableModels.filter { $0.id == selectedModelId }
        let unselected = availableModels.filter { $0.id != selectedModelId }
        return selected + unselected
    }
    
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 520, height: 560)
        .onAppear {
            ensureValidProviderSelection()
            loadModels()
        }
        .onChange(of: providers.map(\.id)) { _, _ in
            ensureValidProviderSelection()
        }
        .onChange(of: selectedProviderId) { _, _ in
            loadModels()
        }
    }
    
    private var header: some View {
        HStack {
            Text("Rerun Task")
                .font(.headline)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
    }
    
    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            Group {
                Text(task.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)
                Text("Original model: \(task.modelId)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text("Provider")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                providerPicker
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text("Model")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Model ID", text: $selectedModelId)
                    .textFieldStyle(.roundedBorder)
            }
            
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search models", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            
            GroupBox("Available Models") {
                modelsContent
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }
    
    private var footer: some View {
        HStack {
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.escape)
            
            Spacer()
            
            Button("Rerun with Selected Model") {
                onConfirm(trimmedProviderId, trimmedModelId)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return)
            .disabled(!canConfirm)
        }
        .padding(16)
    }
    
    private var providerPicker: some View {
        Menu {
            ForEach(providers, id: \.id) { provider in
                Button(provider.displayName) {
                    selectedProviderId = provider.id
                }
            }
        } label: {
            HStack {
                Text(selectedProvider?.displayName ?? "Select provider")
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
    }
    
    @ViewBuilder
    private var modelsContent: some View {
        if isLoadingModels {
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading models...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 180)
        } else if let modelLoadError {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(modelLoadError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    loadModels()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, minHeight: 180)
        } else if filteredModels.isEmpty {
            Text(searchText.isEmpty ? "No models available for this provider." : "No matching models.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 180, alignment: .center)
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filteredModels) { model in
                        modelRow(model)
                    }
                }
            }
            .frame(minHeight: 180, maxHeight: 250)
        }
    }
    
    private func modelRow(_ model: LLMProviderModel) -> some View {
        let isSelected = model.id == selectedModelId
        
        return Button {
            selectedModelId = model.id
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isOpenRouterProvider ? model.displayName : model.id)
                        .font(.body)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if isOpenRouterProvider && model.displayName != model.id {
                        Text(model.id)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
    
    private func ensureValidProviderSelection() {
        if providers.contains(where: { $0.id == selectedProviderId }) {
            return
        }
        
        if providers.contains(where: { $0.id == task.providerId }) {
            selectedProviderId = task.providerId
            return
        }
        
        if let defaultProvider = providers.first(where: { $0.isDefault }) ?? providers.first {
            selectedProviderId = defaultProvider.id
            return
        }
        
        selectedProviderId = ""
    }
    
    private func loadModels() {
        guard let provider = selectedProvider else {
            availableModels = []
            modelLoadError = nil
            return
        }
        
        let apiKey: String
        if provider.authMode == .apiKey {
            guard let stored = provider.retrieveAPIKey() else {
                availableModels = []
                modelLoadError = "No API key configured for this provider."
                return
            }
            apiKey = stored
        } else {
            apiKey = ""
        }
        
        let requestProviderId = provider.id
        isLoadingModels = true
        modelLoadError = nil
        
        Task {
            do {
                let config = provider.makeLLMConfiguration(
                    model: provider.backendMode == .codexOAuth ? "gpt-5-codex" : "model-listing-placeholder",
                    apiKey: apiKey
                )
                let client = LLMService.shared.createClient(from: config)
                let models = try await client.listModelsDetailed()
                    .sorted { lhs, rhs in
                        lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
                    }
                
                await MainActor.run {
                    guard requestProviderId == selectedProviderId else { return }
                    availableModels = models
                    isLoadingModels = false
                    if trimmedModelId.isEmpty, let firstModel = models.first {
                        selectedModelId = firstModel.id
                    }
                }
            } catch {
                await MainActor.run {
                    guard requestProviderId == selectedProviderId else { return }
                    availableModels = []
                    isLoadingModels = false
                    modelLoadError = error.localizedDescription
                }
            }
        }
    }
}
