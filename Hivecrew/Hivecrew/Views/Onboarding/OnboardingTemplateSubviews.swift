//
//  OnboardingTemplateSubviews.swift
//  Hivecrew
//
//  Subviews for the onboarding template step
//

import SwiftUI

// MARK: - Download Progress View

struct TemplateDownloadProgressView: View {
    let progress: TemplateDownloadProgress?
    let onPause: () -> Void
    let onCancel: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            if let progress = progress {
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
                        onPause()
                    }
                    .buttonStyle(.bordered)
                    
                    Button("Cancel Download") {
                        onCancel()
                    }
                    .foregroundStyle(.red)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
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
}

// MARK: - Paused Download View

struct TemplatePausedDownloadView: View {
    let progress: TemplateDownloadProgress?
    let onResume: () -> Void
    let onCancel: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            
            Text("Download Paused")
                .font(.title2)
                .fontWeight(.semibold)
            
            if let progress = progress {
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
                    onResume()
                } label: {
                    HStack {
                        Image(systemName: "play.fill")
                        Text("Resume")
                    }
                }
                .buttonStyle(.borderedProminent)
                
                Button("Cancel") {
                    onCancel()
                }
                .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Resume Download Section

struct TemplateResumeDownloadSection: View {
    let info: (templateId: String, bytesDownloaded: Int64, totalBytes: Int64)?
    let onResume: () -> Void
    let onDiscard: () -> Void
    
    var body: some View {
        VStack(spacing: 12) {
            if let info = info {
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
                    onResume()
                } label: {
                    HStack {
                        Image(systemName: "arrow.clockwise.circle.fill")
                        Text("Resume Download")
                    }
                }
                .buttonStyle(.borderedProminent)
                
                Button(role: .destructive) {
                    onDiscard()
                } label: {
                    HStack {
                        Image(systemName: "trash")
                        Text("Discard")
                    }
                }
            }
        }
    }
}

// MARK: - Empty State View

struct TemplateEmptyStateView: View {
    var body: some View {
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
}

// MARK: - Update Available Banner

struct TemplateUpdateBanner: View {
    let update: RemoteTemplate
    let onUpdate: () -> Void
    
    var body: some View {
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
                onUpdate()
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
}

// MARK: - Template Row

struct TemplateRow: View {
    let template: TemplateInfo
    let isDefault: Bool
    let onSetDefault: () -> Void
    
    var body: some View {
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
            
            if isDefault {
                Text("Default")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.2))
                    .cornerRadius(4)
            } else {
                Button("Set Default") {
                    onSetDefault()
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
}
