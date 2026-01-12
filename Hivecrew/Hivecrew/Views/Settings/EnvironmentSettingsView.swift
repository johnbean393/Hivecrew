//
//  EnvironmentSettingsView.swift
//  Hivecrew
//
//  Settings for ephemeral VM environments (template selection, concurrency limits)
//

import SwiftUI
import UniformTypeIdentifiers
import HivecrewShared

/// Environment settings tab - configure template and concurrency for ephemeral VMs
struct EnvironmentSettingsView: View {
    @EnvironmentObject var vmService: VMServiceClient
    
    @AppStorage("defaultTemplateId") private var defaultTemplateId = ""
    @AppStorage("maxConcurrentVMs") private var maxConcurrentVMs = 2
    
    @State private var templates: [TemplateInfo] = []
    @State private var isLoadingTemplates = false
    @State private var loadError: String?
    @State private var showingImportPicker = false
    @State private var showingDeleteConfirmation = false
    @State private var templateToDelete: TemplateInfo?
    @State private var isImporting = false
    @State private var importError: String?
    
    var body: some View {
        Form {
            templateSelectionSection
            templateManagementSection
            concurrencySection
        }
        .formStyle(.grouped)
        .padding()
        .task {
            await loadTemplates()
        }
        .fileImporter(
            isPresented: $showingImportPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false,
            onCompletion: handleTemplateImport
        )
        .alert("Delete Template?", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                templateToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let template = templateToDelete {
                    Task { await deleteTemplate(template) }
                }
            }
        } message: {
            if let template = templateToDelete {
                Text("Are you sure you want to delete \"\(template.name)\"? This action cannot be undone.")
            }
        }
    }
    
    // MARK: - Template Selection Section
    
    private var templateSelectionSection: some View {
        Section {
            if isLoadingTemplates {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading templates...")
                        .foregroundStyle(.secondary)
                }
            } else if templates.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No templates available")
                        .foregroundStyle(.secondary)
                    Text("Import a template folder to run agent tasks.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Picker("Default Template", selection: $defaultTemplateId) {
                    ForEach(templates) { template in
                        Text(template.name).tag(template.id)
                    }
                }
                
                if let selectedTemplate = templates.first(where: { $0.id == defaultTemplateId }) {
                    templateInfoView(selectedTemplate)
                }
            }
            
            if let error = loadError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Default Template")
        } footer: {
            Text("Agent tasks will create ephemeral VMs from this template. VMs are automatically deleted when tasks complete.")
        }
    }
    
    private func templateInfoView(_ template: TemplateInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !template.description.isEmpty {
                Text(template.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                Label("\(template.cpuCount) CPU", systemImage: "cpu")
                Label(template.memorySizeFormatted, systemImage: "memorychip")
                Label(template.diskSizeFormatted, systemImage: "internaldrive")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }
    
    // MARK: - Template Management Section
    
    private var templateManagementSection: some View {
        Section {
            // Import template button
            Button(action: { showingImportPicker = true }) {
                HStack {
                    Image(systemName: "folder.badge.plus")
                    Text("Import Template Folder...")
                }
            }
            .disabled(isImporting)
            
            if isImporting {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Importing template...")
                        .foregroundStyle(.secondary)
                }
            }
            
            if let error = importError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            
            // List of templates with delete option
            if !templates.isEmpty {
                ForEach(templates) { template in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(template.name)
                                .font(.body)
                            Text(template.diskSizeFormatted)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                        
                        if template.id == defaultTemplateId {
                            Text("Default")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.2))
                                .cornerRadius(4)
                        }
                        
                        Button(action: {
                            templateToDelete = template
                            showingDeleteConfirmation = true
                        }) {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .help("Delete template")
                    }
                    .padding(.vertical, 4)
                }
            }
        } header: {
            Text("Manage Templates")
        } footer: {
            Text("Templates are pre-configured macOS images with the Hivecrew agent installed.")
        }
    }
    
    // MARK: - Concurrency Section
    
    private var concurrencySection: some View {
        Section {
            Stepper("Max Concurrent Tasks: \(maxConcurrentVMs)", value: $maxConcurrentVMs, in: 1...16)
        } header: {
            Text("Concurrency")
        } footer: {
            Text("Maximum number of agent tasks that can run simultaneously. Additional tasks will be queued.")
        }
    }
    
    // MARK: - Data Loading
    
    private func loadTemplates() async {
        isLoadingTemplates = true
        loadError = nil
        
        do {
            templates = try await vmService.listTemplates()
            
            // If current selection is invalid, clear it
            if !defaultTemplateId.isEmpty && !templates.contains(where: { $0.id == defaultTemplateId }) {
                defaultTemplateId = ""
            }
            
            // Auto-select if only one template and none selected
            if defaultTemplateId.isEmpty && templates.count == 1 {
                defaultTemplateId = templates[0].id
            }
        } catch {
            loadError = "Failed to load templates: \(error.localizedDescription)"
        }
        
        isLoadingTemplates = false
    }
    
    // MARK: - Template Import
    
    private func handleTemplateImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task { await importTemplate(from: url) }
            
        case .failure(let error):
            importError = error.localizedDescription
        }
    }
    
    private func importTemplate(from sourceURL: URL) async {
        isImporting = true
        importError = nil
        
        // Start accessing security-scoped resource
        let accessGranted = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessGranted {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        
        // Validate template folder structure
        let configPath = sourceURL.appendingPathComponent("config.json")
        let diskPath = sourceURL.appendingPathComponent("disk.img")
        
        guard FileManager.default.fileExists(atPath: configPath.path),
              FileManager.default.fileExists(atPath: diskPath.path) else {
            importError = "Invalid template folder. Must contain config.json and disk.img"
            isImporting = false
            return
        }
        
        do {
            // Read template config to get name
            let configData = try Data(contentsOf: configPath)
            let configDict = try JSONSerialization.jsonObject(with: configData) as? [String: Any]
            let templateName = configDict?["name"] as? String ?? sourceURL.lastPathComponent
            
            // Generate template ID
            let templateId = UUID().uuidString
            let templateDir = AppPaths.templateBundlePath(id: templateId)
            
            // Copy template files
            try FileManager.default.createDirectory(at: templateDir, withIntermediateDirectories: true)
            
            // Copy disk image
            let diskDest = templateDir.appendingPathComponent("disk.img")
            try FileManager.default.copyItem(at: diskPath, to: diskDest)
            
            // Copy auxiliary storage if present
            let auxSource = sourceURL.appendingPathComponent("auxiliary")
            let auxDest = templateDir.appendingPathComponent("auxiliary")
            if FileManager.default.fileExists(atPath: auxSource.path) {
                try FileManager.default.copyItem(at: auxSource, to: auxDest)
            }
            
            // Copy hardware model if present
            let hwSource = sourceURL.appendingPathComponent("HardwareModel.bin")
            let hwDest = templateDir.appendingPathComponent("HardwareModel.bin")
            if FileManager.default.fileExists(atPath: hwSource.path) {
                try FileManager.default.copyItem(at: hwSource, to: hwDest)
            }
            
            // Get disk size
            let diskAttrs = try FileManager.default.attributesOfItem(atPath: diskDest.path)
            let diskSize = diskAttrs[.size] as? UInt64 ?? 0
            
            // Extract config values
            let cpuCount = configDict?["cpuCount"] as? Int ?? 2
            let memorySize = configDict?["memorySize"] as? UInt64 ?? (4 * 1024 * 1024 * 1024)
            let description = configDict?["description"] as? String ?? ""
            
            // Create new config with our template ID
            let newConfig: [String: Any] = [
                "id": templateId,
                "name": templateName,
                "description": description,
                "createdAt": ISO8601DateFormatter().string(from: Date()),
                "diskSize": diskSize,
                "cpuCount": cpuCount,
                "memorySize": memorySize
            ]
            
            let newConfigData = try JSONSerialization.data(withJSONObject: newConfig, options: .prettyPrinted)
            try newConfigData.write(to: templateDir.appendingPathComponent("config.json"))
            
            print("EnvironmentSettingsView: Imported template '\(templateName)' as \(templateId)")
            
            // Reload templates
            await loadTemplates()
            
            // Auto-select if this is the first template
            if templates.count == 1 {
                defaultTemplateId = templateId
            }
            
        } catch {
            importError = "Failed to import template: \(error.localizedDescription)"
        }
        
        isImporting = false
    }
    
    // MARK: - Template Deletion
    
    private func deleteTemplate(_ template: TemplateInfo) async {
        do {
            try await vmService.deleteTemplate(templateId: template.id)
            
            // Clear selection if we deleted the default
            if defaultTemplateId == template.id {
                defaultTemplateId = ""
            }
            
            // Reload templates
            await loadTemplates()
        } catch {
            loadError = "Failed to delete template: \(error.localizedDescription)"
        }
        
        templateToDelete = nil
    }
}

#Preview {
    EnvironmentSettingsView()
        .environmentObject(VMServiceClient.shared)
        .frame(width: 500, height: 500)
}
