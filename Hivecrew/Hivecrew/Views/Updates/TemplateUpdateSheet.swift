//
//  TemplateUpdateSheet.swift
//  Hivecrew
//
//  Sheet for prompting users about template updates
//

import SwiftUI
import HivecrewShared

/// Sheet displayed when a template update is available
struct TemplateUpdateSheet: View {
    @Binding var isPresented: Bool
    @StateObject private var downloadService = TemplateDownloadService.shared
    @AppStorage("defaultTemplateId") private var defaultTemplateId = ""
    
    let update: RemoteTemplate
    let currentTemplateId: String?
    
    @State private var downloadError: String?
    @State private var isUpdating = false
    @State private var updateComplete = false
    
    var body: some View {
        VStack(spacing: 24) {
            if downloadService.isDownloading {
                downloadProgressView
            } else if downloadService.isPaused {
                pausedView
            } else if updateComplete {
                updateCompleteView
            } else {
                updatePromptView
            }
        }
        .padding(32)
        .frame(width: 480)
    }
    
    // MARK: - Paused View
    
    private var pausedView: some View {
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
            }
            
            HStack(spacing: 16) {
                Button {
                    Task { await performUpdate() }
                } label: {
                    HStack {
                        Image(systemName: "play.fill")
                        Text("Resume")
                    }
                }
                .buttonStyle(.borderedProminent)
                
                Button("Cancel") {
                    downloadService.cancelAndDeleteDownload()
                    isPresented = false
                }
                .foregroundStyle(.red)
            }
        }
    }
    
    // MARK: - Update Prompt View
    
    private var updatePromptView: some View {
        VStack(spacing: 20) {
            // Icon
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.blue)
            
            // Title
            Text("Template Update Available")
                .font(.title2)
                .fontWeight(.semibold)
            
            // Description
            VStack(spacing: 8) {
                Text("A new version of the Hivecrew Golden Image is available.")
                    .multilineTextAlignment(.center)
                
                Text("Version \(update.version)")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            
            // Error message
            if let error = downloadError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            
            // Buttons
            VStack(spacing: 12) {
                Button {
                    Task { await performUpdate() }
                } label: {
                    Text("Update Now")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                
                HStack(spacing: 16) {
                    Button("Ask Later") {
                        downloadService.askLater()
                        isPresented = false
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    
                    Button("Skip This Version") {
                        downloadService.skipVersion(update.version)
                        isPresented = false
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8)
        }
    }
    
    // MARK: - Download Progress View
    
    private var downloadProgressView: some View {
        VStack(spacing: 20) {
            if let progress = downloadService.progress {
                // Icon changes based on phase
                Image(systemName: progressIcon(for: progress.phase))
                    .font(.system(size: 48))
                    .foregroundStyle(.blue)
                
                Text("Updating Template")
                    .font(.title2)
                    .fontWeight(.semibold)
                
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
                
                // Pause and Cancel buttons
                HStack(spacing: 16) {
                    if case .downloading = progress.phase {
                        Button("Pause") {
                            downloadService.pauseDownload()
                        }
                        .buttonStyle(.bordered)
                    }
                    
                    Button("Cancel") {
                        downloadService.cancelDownload()
                        isPresented = false
                    }
                    .foregroundStyle(.red)
                }
            }
        }
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
    
    // MARK: - Update Complete View
    
    private var updateCompleteView: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            
            Text("Update Complete")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("The template has been updated to version \(update.version).")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            
            Button("Done") {
                isPresented = false
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
    
    // MARK: - Helper Methods
    
    private func progressIcon(for phase: TemplateDownloadProgress.Phase) -> String {
        switch phase {
        case .downloading:
            return "arrow.down.circle"
        case .decompressing:
            return "archivebox"
        case .extracting:
            return "doc.zipper"
        case .configuring:
            return "gearshape"
        case .complete:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        }
    }
    
    private func performUpdate() async {
        downloadError = nil
        isUpdating = true
        
        do {
            let newTemplateId = try await downloadService.updateTemplate(
                update,
                removingOld: currentTemplateId
            )
            
            // Set the new template as default
            defaultTemplateId = newTemplateId
            updateComplete = true
            
        } catch {
            if case TemplateDownloadError.cancelled = error {
                // User cancelled, check for resumable
                downloadService.checkForResumableDownload()
                return
            }
            downloadError = error.localizedDescription
            downloadService.checkForResumableDownload()
        }
        
        isUpdating = false
    }
}

#Preview {
    TemplateUpdateSheet(
        isPresented: .constant(true),
        update: KnownTemplates.default,
        currentTemplateId: "golden-v0.0.5"
    )
}
