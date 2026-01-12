//
//  OnboardingTemplateStep.swift
//  Hivecrew
//
//  VM Template setup step of the onboarding wizard
//

import SwiftUI
import UniformTypeIdentifiers
import HivecrewShared

/// VM Template configuration step
struct OnboardingTemplateStep: View {
    @EnvironmentObject var vmService: VMServiceClient
    @AppStorage("defaultTemplateId") private var defaultTemplateId = ""
    
    @Binding var isConfigured: Bool
    
    @State private var templates: [TemplateInfo] = []
    @State private var isLoading = false
    @State private var showingImportPicker = false
    @State private var isImporting = false
    @State private var importError: String?
    
    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                
                Text("Add a VM Template")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text("Templates are pre-configured macOS images with the Hivecrew agent installed")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 20)
            
            // Templates list or empty state
            if isLoading {
                ProgressView("Loading templates...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if templates.isEmpty {
                emptyState
            } else {
                templatesList
            }
            
            // Import button
            VStack(spacing: 8) {
                Button {
                    showingImportPicker = true
                } label: {
                    HStack {
                        Image(systemName: "folder.badge.plus")
                        Text("Import Template Folder...")
                    }
                }
                .disabled(isImporting)
                
                if isImporting {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Importing template...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                if let error = importError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(.bottom, 20)
        }
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
        .onChange(of: templates.count) { _, newCount in
            isConfigured = newCount > 0
        }
    }
    
    // MARK: - Empty State
    
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            
            Text("No templates found")
                .font(.headline)
                .foregroundStyle(.secondary)
            
            Text("Import a template folder containing a pre-configured\nmacOS VM with the Hivecrew agent installed.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Templates List
    
    private var templatesList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Available Templates")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 60)
            
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(templates) { template in
                        templateRow(template)
                    }
                }
                .padding(.horizontal, 60)
            }
            .frame(maxHeight: 150)
        }
    }
    
    private func templateRow(_ template: TemplateInfo) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(template.name)
                    .fontWeight(.medium)
                HStack(spacing: 12) {
                    Label("\(template.cpuCount) CPU", systemImage: "cpu")
                    Label(template.memorySizeFormatted, systemImage: "memorychip")
                    Label(template.diskSizeFormatted, systemImage: "internaldrive")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            if template.id == defaultTemplateId {
                Text("Default")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.2))
                    .cornerRadius(4)
            } else {
                Button("Set Default") {
                    defaultTemplateId = template.id
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.caption)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
    
    // MARK: - Data Loading
    
    private func loadTemplates() async {
        isLoading = true
        
        do {
            templates = try await vmService.listTemplates()
            
            // Auto-select if only one template
            if defaultTemplateId.isEmpty && templates.count == 1 {
                defaultTemplateId = templates[0].id
            }
            
            isConfigured = !templates.isEmpty
        } catch {
            print("Failed to load templates: \(error)")
        }
        
        isLoading = false
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
        
        let accessGranted = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessGranted {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        
        let configPath = sourceURL.appendingPathComponent("config.json")
        let diskPath = sourceURL.appendingPathComponent("disk.img")
        
        guard FileManager.default.fileExists(atPath: configPath.path),
              FileManager.default.fileExists(atPath: diskPath.path) else {
            importError = "Invalid template folder. Must contain config.json and disk.img"
            isImporting = false
            return
        }
        
        do {
            let configData = try Data(contentsOf: configPath)
            let configDict = try JSONSerialization.jsonObject(with: configData) as? [String: Any]
            let templateName = configDict?["name"] as? String ?? sourceURL.lastPathComponent
            
            let templateId = UUID().uuidString
            let templateDir = AppPaths.templateBundlePath(id: templateId)
            
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
            
            // Create new config
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
            
            // Reload templates
            await loadTemplates()
            
            // Auto-select if first template
            if templates.count == 1 {
                defaultTemplateId = templateId
            }
            
        } catch {
            importError = "Failed to import: \(error.localizedDescription)"
        }
        
        isImporting = false
    }
}

#Preview {
    OnboardingTemplateStep(isConfigured: .constant(false))
        .environmentObject(VMServiceClient.shared)
        .frame(width: 600, height: 450)
}
