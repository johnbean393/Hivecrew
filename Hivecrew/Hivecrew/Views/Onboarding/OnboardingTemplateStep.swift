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
                downloadProgressView
            } else if downloadService.isPaused {
                pausedDownloadView
            } else if templates.isEmpty {
                emptyState
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
    
    // MARK: - Download Progress View
    
    private var downloadProgressView: some View {
        VStack(spacing: 20) {
            if let progress = downloadService.progress {
                // Progress indicator
                VStack(spacing: 12) {
                    ProgressView(value: progress.fractionComplete)
                        .progressViewStyle(.linear)
                    
                    HStack {
                        Text(progress.phaseDescription)
                            .font(.callout)
                        
                        Spacer()
                        
                        if case .downloading = progress.phase {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(ByteCountFormatter.string(fromByteCount: progress.bytesDownloaded, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                
                                if let timeRemaining = progress.estimatedTimeRemaining {
                                    Text(formatTimeRemaining(timeRemaining))
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        } else {
                            Text("\(progress.percentComplete)%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 60)
                
                // Pause and Cancel buttons
                HStack(spacing: 16) {
                    Button("Pause") {
                        downloadService.pauseDownload()
                    }
                    .buttonStyle(.bordered)
                    
                    Button("Cancel Download") {
                        downloadService.cancelDownload()
                    }
                    .foregroundStyle(.red)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    /// Format time remaining as human-readable string
    private func formatTimeRemaining(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return "Less than a minute remaining"
        } else if seconds < 3600 {
            let minutes = Int(seconds / 60)
            return "\(minutes) minute\(minutes == 1 ? "" : "s") remaining"
        } else {
            let hours = Int(seconds / 3600)
            let minutes = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
            if minutes == 0 {
                return "\(hours) hour\(hours == 1 ? "" : "s") remaining"
            }
            return "\(hours)h \(minutes)m remaining"
        }
    }
    
    // MARK: - Paused Download View
    
    private var pausedDownloadView: some View {
        VStack(spacing: 20) {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            
            Text("Download Paused")
                .font(.title2)
                .fontWeight(.semibold)
            
            if let progress = downloadService.progress {
                VStack(spacing: 12) {
                    ProgressView(value: progress.fractionComplete)
                        .progressViewStyle(.linear)
                    
                    Text("\(ByteCountFormatter.string(fromByteCount: progress.bytesDownloaded, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 60)
            }
            
            HStack(spacing: 16) {
                Button {
                    Task { await resumeDownload() }
                } label: {
                    HStack {
                        Image(systemName: "play.fill")
                        Text("Resume")
                    }
                }
                .buttonStyle(.borderedProminent)
                
                Button("Cancel") {
                    downloadService.cancelAndDeleteDownload()
                }
                .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Action Buttons
    
    private var actionButtons: some View {
        VStack(spacing: 12) {
            // Resume button if there's a partial download
            if downloadService.hasResumableDownload {
                resumeDownloadSection
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
    
    // MARK: - Resume Download Section
    
    private var resumeDownloadSection: some View {
        VStack(spacing: 12) {
            if let info = downloadService.getResumableDownloadInfo() {
                VStack(spacing: 4) {
                    Text("Incomplete Download Found")
                        .font(.headline)
                    
                    Text("\(ByteCountFormatter.string(fromByteCount: info.bytesDownloaded, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: info.totalBytes, countStyle: .file)) downloaded")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    // Progress bar showing downloaded portion
                    ProgressView(value: Double(info.bytesDownloaded), total: Double(info.totalBytes))
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 300)
                }
                .padding(.vertical, 8)
            }
            
            HStack(spacing: 16) {
                Button {
                    Task { await resumeDownload() }
                } label: {
                    HStack {
                        Image(systemName: "arrow.clockwise.circle.fill")
                        Text("Resume Download")
                    }
                }
                .buttonStyle(.borderedProminent)
                
                Button(role: .destructive) {
                    downloadService.clearPartialDownload()
                } label: {
                    HStack {
                        Image(systemName: "trash")
                        Text("Discard")
                    }
                }
            }
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
            
            Text("Download the official Hivecrew Golden Image or import a template folder\ncontaining a pre-configured macOS VM.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Templates List
    
    private var templatesList: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Update available banner
            if downloadService.updateAvailable, let update = downloadService.availableUpdate {
                updateAvailableBanner(update)
                    .padding(.horizontal, 60)
            }
            
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
    
    // MARK: - Update Available Banner
    
    private func updateAvailableBanner(_ update: RemoteTemplate) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title2)
                .foregroundStyle(.blue)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Template Update Available")
                    .font(.headline)
                Text("Version \(update.version)" + (update.sizeFormatted.map { " • \($0)" } ?? ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Button("Update") {
                Task { await downloadUpdate(update) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(12)
        .background(Color.blue.opacity(0.1))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.blue.opacity(0.3), lineWidth: 1)
        )
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
            
            // Auto-select the downloaded template as default
            defaultTemplateId = templateId
            
            // Reload templates to show the new one
            await loadTemplates()
        } catch {
            if case TemplateDownloadError.cancelled = error {
                // User cancelled, don't show error but check for resumable
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
            
            // Auto-select the downloaded template as default
            defaultTemplateId = templateId
            
            // Reload templates to show the new one
            await loadTemplates()
        } catch {
            if case TemplateDownloadError.cancelled = error {
                // User cancelled, don't show error
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
            
            // Auto-select the updated template as default
            defaultTemplateId = templateId
            
            // Reload templates to show the updated one
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
