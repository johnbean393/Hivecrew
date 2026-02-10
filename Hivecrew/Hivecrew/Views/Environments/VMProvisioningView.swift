//
//  VMProvisioningView.swift
//  Hivecrew
//
//  Sheet for configuring VM provisioning: environment variables, setup commands, and file injections
//

import SwiftUI
import UniformTypeIdentifiers
import HivecrewShared

/// Sheet for editing the global VM provisioning configuration
struct VMProvisioningView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var provisioningService = VMProvisioningService.shared
    
    /// Local working copy of the config (saved on explicit save)
    @State private var config: VMProvisioningConfig = .empty
    
    /// File importer state
    @State private var showingFilePicker = false
    @State private var importError: String?
    
    /// Track if changes have been made
    private var hasChanges: Bool {
        config != provisioningService.config
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            header
            
            Divider()
            
            // Content
            ScrollView {
                VStack(spacing: 20) {
                    environmentVariablesSection
                    setupCommandsSection
                    fileInjectionsSection
                }
                .padding()
            }
            
            Divider()
            
            // Footer
            footer
        }
        .frame(width: 600, height: 550)
        .onAppear {
            config = provisioningService.config
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false,
            onCompletion: handleFileImport
        )
    }
    
    // MARK: - Header
    
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("VM Configuration")
                    .font(.headline)
                Text("Configure environment variables, startup commands, and files injected into every new VM.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
    }
    
    // MARK: - Footer
    
    private var footer: some View {
        HStack {
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            
            Spacer()
            
            Button("Save") {
                provisioningService.config = config
                provisioningService.save()
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!hasChanges)
        }
        .padding()
    }
    
    // MARK: - Environment Variables Section
    
    private var environmentVariablesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Environment Variables", systemImage: "list.bullet.rectangle")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    config.environmentVariables.append(.init())
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("Add environment variable")
            }
            
            Text("Key-value pairs exported into the shell environment for every command run in the VM.")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            if config.environmentVariables.isEmpty {
                Text("No environment variables defined.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 6) {
                    // Column headers
                    HStack(spacing: 8) {
                        Text("Key")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Value")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        // Spacer for delete button
                        Color.clear.frame(width: 24)
                    }
                    .padding(.horizontal, 4)
                    
                    ForEach($config.environmentVariables) { $envVar in
                        HStack(spacing: 8) {
                            TextField("KEY", text: $envVar.key)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                            
                            TextField("value", text: $envVar.value)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                            
                            Button {
                                config.environmentVariables.removeAll { $0.id == envVar.id }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                            .help("Remove variable")
                        }
                    }
                }
            }
        }
        .padding()
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    
    // MARK: - Setup Commands Section
    
    private var setupCommandsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Setup Commands", systemImage: "terminal")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    config.setupCommands.append("")
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("Add setup command")
            }
            
            Text("Shell commands executed in order after the VM boots, before the agent starts working.")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            if config.setupCommands.isEmpty {
                Text("No setup commands defined.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 6) {
                    ForEach(config.setupCommands.indices, id: \.self) { index in
                        HStack(spacing: 8) {
                            Text("\(index + 1).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 20, alignment: .trailing)
                            
                            TextField("e.g. brew install jq", text: $config.setupCommands[index])
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                            
                            Button {
                                config.setupCommands.remove(at: index)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                            .help("Remove command")
                        }
                    }
                }
            }
        }
        .padding()
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    
    // MARK: - File Injections Section
    
    private var fileInjectionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("File Injections", systemImage: "doc.on.doc")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    showingFilePicker = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("Add File...")
                    }
                }
                .buttonStyle(.plain)
                .help("Select a file from your Mac to inject into VMs")
            }
            
            Text("Files are copied into each new VM at the specified path. Source files are referenced directly, so updates on your Mac are picked up automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            if let error = importError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            
            if config.fileInjections.isEmpty {
                Text("No files configured for injection.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 8) {
                    ForEach($config.fileInjections) { $injection in
                        VStack(spacing: 4) {
                            HStack(spacing: 8) {
                                Image(systemName: "doc.fill")
                                    .foregroundStyle(.secondary)
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(injection.resolvedFileName)
                                        .font(.system(.body, design: .monospaced))
                                        .lineLimit(1)
                                    
                                    if let sourceFilePath = injection.sourceFilePath, !sourceFilePath.isEmpty {
                                        Text(sourceFilePath)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    
                                    if !provisioningService.fileInjectionSourceExists(injection) {
                                        Text(injection.hasLiveSourceReference ? "Source file unavailable" : "File missing from assets")
                                            .font(.caption2)
                                            .foregroundStyle(.red)
                                    }
                                }
                                
                                Spacer()
                                
                                Button {
                                    // For legacy snapshot-based entries, also remove the stored asset copy.
                                    if !injection.hasLiveSourceReference {
                                        provisioningService.removeFile(named: injection.fileName)
                                    }
                                    config.fileInjections.removeAll { $0.id == injection.id }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                                .help("Remove file")
                            }
                            
                            HStack(spacing: 4) {
                                Text("VM path:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                
                                TextField("~/Documents/config.yaml", text: $injection.guestPath)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.caption, design: .monospaced))
                            }
                        }
                        .padding(8)
                        .background(.background)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
        .padding()
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    
    // MARK: - File Import
    
    private func handleFileImport(_ result: Result<[URL], Error>) {
        importError = nil
        
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            
            do {
                let injection = try provisioningService.createFileInjection(from: url)
                config.fileInjections.append(injection)
            } catch {
                importError = "Failed to import file: \(error.localizedDescription)"
            }
            
        case .failure(let error):
            importError = "File picker error: \(error.localizedDescription)"
        }
    }
}

#Preview {
    VMProvisioningView()
        .frame(width: 600, height: 550)
}
