//
//  PromptModelButton.swift
//  Hivecrew
//
//  Capsule-style model picker button with popover selection
//

import SwiftUI
import HivecrewLLM

/// A capsule-styled button for selecting the LLM model, similar to the Search button design
struct PromptModelButton: View {
    
    @Binding var selectedProviderId: String
    @Binding var selectedModelId: String
    let providers: [LLMProviderRecord]
    var isFocused: Bool = false
    
    @State private var showingPopover: Bool = false
    @State private var isHovering: Bool = false
    
    var selectedProvider: LLMProviderRecord? {
        providers.first(where: { $0.id == selectedProviderId })
    }
    
    var displayText: String {
        if selectedModelId.isEmpty {
            return selectedProvider?.displayName ?? "Select Model"
        } else {
            return selectedModelId
        }
    }
    
    var hasValidSelection: Bool {
        !selectedProviderId.isEmpty && !selectedModelId.isEmpty
    }
    
    /// Use accent color only when focused and has a valid selection
    var textColor: Color {
        if isFocused && hasValidSelection {
            return .accentColor
        }
        return (hasValidSelection ? Color.primary : Color.secondary).opacity(0.5)
    }
    
    var bubbleColor: Color {
        if isFocused && hasValidSelection {
            return Color.accentColor.opacity(0.3)
        }
        return .white.opacity(0.0001)
    }
    
    var bubbleBorderColor: Color {
        if isFocused && hasValidSelection {
            return bubbleColor
        }
        return .primary.opacity(0.3)
    }
    
    var body: some View {
        Button {
            showingPopover = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "brain")
                    .font(.caption)
                Text(displayText)
                    .font(.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(textColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                capsuleBackground
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            PromptModelPopover(
                selectedProviderId: $selectedProviderId,
                selectedModelId: $selectedModelId,
                providers: providers,
                isPresented: $showingPopover
            )
        }
    }
    
    private var capsuleBackground: some View {
        ZStack {
            Capsule()
                .fill(bubbleColor)
            Capsule()
                .stroke(style: StrokeStyle(lineWidth: 0.3))
                .fill(bubbleBorderColor)
        }
    }
}

// MARK: - Model Picker Popover

/// Popover with searchable model list
struct PromptModelPopover: View {
    @Binding var selectedProviderId: String
    @Binding var selectedModelId: String
    let providers: [LLMProviderRecord]
    @Binding var isPresented: Bool
    
    @State private var searchText: String = ""
    @State private var availableModels: [String] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    
    var selectedProvider: LLMProviderRecord? {
        providers.first(where: { $0.id == selectedProviderId })
    }
    
    var filteredModels: [String] {
        if searchText.isEmpty {
            return availableModels
        }
        return availableModels.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Provider selector
            if providers.count > 1 {
                providerSection
                Divider()
            }
            
            // Search field
            searchField
            
            Divider()
            
            // Model list
            modelList
        }
        .frame(width: 280, height: 350)
        .onAppear {
            loadModels()
        }
        .onChange(of: selectedProviderId) { oldValue, newValue in
            loadModels()
        }
    }
    
    // MARK: - Provider Section
    
    private var providerSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(providers, id: \.id) { provider in
                    providerChip(provider)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
    
    private func providerChip(_ provider: LLMProviderRecord) -> some View {
        let isSelected = provider.id == selectedProviderId
        
        return Button(action: {
            selectedProviderId = provider.id
            
            // Force UserDefaults to synchronize immediately
            UserDefaults.standard.set(provider.id, forKey: "lastSelectedProviderId")
            UserDefaults.standard.synchronize()
            
            // Clear the model selection when switching providers
            selectedModelId = ""
            UserDefaults.standard.set("", forKey: "lastSelectedModelId")
            UserDefaults.standard.synchronize()
        }) {
            Text(provider.displayName)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(isSelected ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Search Field
    
    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary)
            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
    
    // MARK: - Model List
    
    private var modelList: some View {
        Group {
            if isLoading {
                loadingView
            } else if let error = errorMessage {
                errorView(error)
            } else if filteredModels.isEmpty {
                emptyView
            } else {
                modelListContent
            }
        }
    }
    
    private var loadingView: some View {
        VStack {
            Spacer()
            ProgressView()
                .scaleEffect(0.8)
            Text("Loading models...")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            Spacer()
        }
    }
    
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.orange)
            Text("Failed to load models")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Retry") {
                loadModels()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Spacer()
        }
    }
    
    private var emptyView: some View {
        VStack {
            Spacer()
            Text(searchText.isEmpty ? "No models available" : "No matching models")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
    
    private var modelListContent: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(filteredModels, id: \.self) { model in
                    modelRow(model)
                }
            }
            .padding(.vertical, 4)
        }
    }
    
    private func modelRow(_ model: String) -> some View {
        let isSelected = model == selectedModelId
        
        return Button(action: {
            selectedModelId = model
            
            // Force UserDefaults to synchronize immediately
            UserDefaults.standard.set(model, forKey: "lastSelectedModelId")
            UserDefaults.standard.synchronize()
            
            // Dismiss after a small delay to ensure the binding propagates
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isPresented = false
            }
        }) {
            HStack {
                Text(model)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Load Models
    
    private func loadModels() {
        guard let provider = selectedProvider else {
            availableModels = []
            return
        }
        
        // Get API key
        guard let apiKey = provider.retrieveAPIKey() else {
            errorMessage = "No API key configured"
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
                    model: "gpt-5.2", // Placeholder, not used for listing
                    organizationId: provider.organizationId,
                    timeoutInterval: provider.timeoutInterval
                )
                
                let client = LLMService.shared.createClient(from: config)
                let models = try await client.listModels()
                
                await MainActor.run {
                    self.availableModels = models
                    self.isLoading = false
                    // If no model selected, pick first one
                    if selectedModelId.isEmpty, let first = self.availableModels.first {
                        selectedModelId = first
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                    
                    // Fallback to hardcoded models on error
                    self.availableModels = ["gpt-5.2"]
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    PromptModelButton(
        selectedProviderId: .constant("test"),
        selectedModelId: .constant("gpt-5.2"),
        providers: []
    )
    .padding()
}
