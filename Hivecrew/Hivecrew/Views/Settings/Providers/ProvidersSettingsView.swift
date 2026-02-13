//
//  ProvidersSettingsView.swift
//  Hivecrew
//
//  LLM Providers settings tab with full provider management
//

import SwiftUI
import SwiftData
import TipKit

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
    
    // Tips
    private let configureProvidersTip = ConfigureProvidersTip()
    
    var body: some View {
        Form {
            providersListSection
            workerModelSection
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            TipStore.shared.updateProviderCount(providers.count)
        }
        .onChange(of: providers.count) { _, newCount in
            TipStore.shared.updateProviderCount(newCount)
        }
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
                .popoverTip(configureProvidersTip, arrowEdge: .trailing)
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

#Preview {
    ProvidersSettingsView()
        .modelContainer(for: LLMProviderRecord.self, inMemory: true)
}
