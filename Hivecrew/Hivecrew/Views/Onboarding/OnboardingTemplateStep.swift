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
    @StateObject private var downloadService = TemplateDownloadService.shared
    @AppStorage("defaultTemplateId") private var defaultTemplateId = ""
    
    @Binding var isConfigured: Bool
    
    @State private var templates: [TemplateInfo] = []
    @State private var isLoading = false
    @State private var showingImportPicker = false
    @State private var isImporting = false
    @State private var importError: String?
    @State private var downloadError: String?
    @State private var showDownloadOptions = false
    
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
            } else if downloadService.isDownloading {
                TemplateDownloadProgressView(
                    progress: downloadService.progress,
                    onPause: { downloadService.pauseDownload() },
                    onCancel: { downloadService.cancelDownload() }
                )
            } else if downloadService.isPaused {
                TemplatePausedDownloadView(
                    progress: downloadService.progress,
                    onResume: { Task { await resumeDownload() } },
                    onCancel: { downloadService.cancelAndDeleteDownload() }
                )
            } else if templates.isEmpty {
                TemplateEmptyStateView()
            } else {
                templatesList
            }
            
            // Action buttons
            if !downloadService.isDownloading && !downloadService.isPaused {
                actionButtons
            }
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
    
    // MARK: - Action Buttons
    
    private var actionButtons: some View {
        VStack(spacing: 12) {
            // Resume button if there's a partial download
            if downloadService.hasResumableDownload {
                TemplateResumeDownloadSection(
                    info: downloadService.getResumableDownloadInfo(),
                    onResume: { Task { await resumeDownload() } },
                    onDiscard: { downloadService.clearPartialDownload() }
                )
            } else if templates.isEmpty {
                // Download button (primary action for empty state)
                Button {
                    Task { await downloadDefaultTemplate() }
                } label: {
                    HStack {
                        Image(systemName: "arrow.down.circle.fill")
                        if let size = KnownTemplates.default.sizeFormatted {
                            Text("Download Golden Image (\(size))")
                        } else {
                            Text("Download Golden Image")
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isImporting)
            }
            
            // Import button
            HStack(spacing: 16) {
                Button {
                    showingImportPicker = true
                } label: {
                    HStack {
                        Image(systemName: "folder.badge.plus")
                        Text("Import Template Folder...")
                    }
                }
                .disabled(isImporting)
                
                if !templates.isEmpty && !downloadService.hasResumableDownload {
                    Button {
                        Task { await downloadDefaultTemplate() }
                    } label: {
                        HStack {
                            Image(systemName: "arrow.down.circle")
                            Text("Download Template...")
                        }
                    }
                    .disabled(isImporting)
                }
            }
            
            if isImporting {
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Importing template...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            if let error = importError ?? downloadError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.bottom, 20)
    }
    
    // MARK: - Templates List
    
    private var templatesList: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Update available banner
            if downloadService.updateAvailable, let update = downloadService.availableUpdate {
                TemplateUpdateBanner(update: update) {
                    Task { await downloadUpdate(update) }
                }
                .padding(.horizontal, 60)
            }
            
            Text("Available Templates")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 60)
            
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(templates) { template in
                        TemplateRow(
                            template: template,
                            isDefault: template.id == defaultTemplateId,
                            onSetDefault: { defaultTemplateId = template.id }
                        )
                    }
                }
                .padding(.horizontal, 60)
            }
            .frame(maxHeight: 150)
        }
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
            
            // Check for updates if we have templates
            if !templates.isEmpty {
                await downloadService.checkForUpdates()
            }
        } catch {
            print("Failed to load templates: \(error)")
        }
        
        isLoading = false
    }
    
    // MARK: - Template Download
    
    private func downloadDefaultTemplate() async {
        downloadError = nil
        
        do {
            let templateId = try await downloadService.downloadTemplate(KnownTemplates.default)
            defaultTemplateId = templateId
            await loadTemplates()
        } catch {
            if case TemplateDownloadError.cancelled = error {
                downloadService.checkForResumableDownload()
                return
            }
            downloadError = error.localizedDescription
            downloadService.checkForResumableDownload()
        }
    }
    
    private func resumeDownload() async {
        downloadError = nil
        
        do {
            let templateId = try await downloadService.resumeDownload()
            defaultTemplateId = templateId
            await loadTemplates()
        } catch {
            if case TemplateDownloadError.cancelled = error {
                downloadService.checkForResumableDownload()
                return
            }
            downloadError = error.localizedDescription
            downloadService.checkForResumableDownload()
        }
    }
    
    private func downloadUpdate(_ update: RemoteTemplate) async {
        downloadError = nil
        
        do {
            let templateId = try await downloadService.downloadTemplate(update)
            defaultTemplateId = templateId
            await loadTemplates()
        } catch {
            if case TemplateDownloadError.cancelled = error {
                downloadService.checkForResumableDownload()
                return
            }
            downloadError = error.localizedDescription
            downloadService.checkForResumableDownload()
        }
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
