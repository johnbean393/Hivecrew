//
//  MissingAttachmentsSheet.swift
//  Hivecrew
//
//  Sheet for handling missing attachments when rerunning a task
//

import SwiftUI
import UniformTypeIdentifiers

/// Sheet displayed when rerunning a task with missing attachments
/// Allows the user to reselect missing files or cancel the rerun
struct MissingAttachmentsSheet: View {
    
    /// The task being rerun
    let task: TaskRecord
    
    /// Missing attachment infos
    let missingAttachments: [AttachmentInfo]
    
    /// Valid attachment infos (already found)
    let validAttachments: [AttachmentInfo]
    
    /// Callback when rerun is confirmed with resolved attachments
    let onConfirm: ([AttachmentInfo]) -> Void
    
    /// Callback when rerun is cancelled
    let onCancel: () -> Void
    
    /// Replacement files selected by user (keyed by original path)
    @State private var replacements: [String: URL] = [:]
    
    /// Currently showing file picker for this attachment
    @State private var selectingFileFor: AttachmentInfo?
    
    /// Whether to skip missing attachments and proceed anyway
    @State private var skipMissing: Bool = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.orange)
                
                Text("Missing Attachments")
                    .font(.headline)
                
                Text("Some files attached to the original task could not be found.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 20)
            .padding(.bottom, 16)
            
            Divider()
            
            // Missing files list
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(missingAttachments, id: \.originalPath) { info in
                        MissingAttachmentRow(
                            info: info,
                            replacement: replacements[info.originalPath],
                            onSelectReplacement: {
                                selectingFileFor = info
                            },
                            onClearReplacement: {
                                replacements.removeValue(forKey: info.originalPath)
                            }
                        )
                    }
                }
                .padding()
            }
            .frame(maxHeight: 300)
            
            Divider()
            
            // Options
            VStack(spacing: 12) {
                Toggle("Skip missing files and proceed anyway", isOn: $skipMissing)
                    .toggleStyle(.checkbox)
                    .font(.subheadline)
                
                if !validAttachments.isEmpty {
                    Text("\(validAttachments.count) file(s) will still be attached")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            
            Divider()
            
            // Buttons
            HStack(spacing: 12) {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button("Rerun Task") {
                    confirmRerun()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canConfirm)
            }
            .padding()
        }
        .frame(width: 450)
        .fileImporter(
            isPresented: Binding(
                get: { selectingFileFor != nil },
                set: { if !$0 { selectingFileFor = nil } }
            ),
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result,
               let url = urls.first,
               let info = selectingFileFor {
                replacements[info.originalPath] = url
            }
            selectingFileFor = nil
        }
    }
    
    /// Whether the confirm button should be enabled
    private var canConfirm: Bool {
        // Can confirm if all missing files have replacements, or if skipping is enabled
        skipMissing || replacements.count == missingAttachments.count
    }
    
    /// Confirm the rerun with resolved attachments
    private func confirmRerun() {
        var resolvedInfos = validAttachments
        
        if !skipMissing {
            // Add replacement files as new attachments
            for (originalPath, replacementURL) in replacements {
                // Create new attachment info for the replacement
                let info = AttachmentInfo(path: replacementURL.path)
                resolvedInfos.append(info)
            }
        }
        
        onConfirm(resolvedInfos)
    }
}

/// Row for a single missing attachment
private struct MissingAttachmentRow: View {
    let info: AttachmentInfo
    let replacement: URL?
    let onSelectReplacement: () -> Void
    let onClearReplacement: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // File icon
            Image(systemName: replacement != nil ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(replacement != nil ? .green : .red)
                .font(.title3)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(info.fileName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                if let replacement = replacement {
                    Text(replacement.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Text(info.originalPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            
            Spacer()
            
            if replacement != nil {
                Button(action: onClearReplacement) {
                    Image(systemName: "xmark")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            
            Button(replacement != nil ? "Change" : "Select File") {
                onSelectReplacement()
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

#Preview {
    MissingAttachmentsSheet(
        task: TaskRecord(
            title: "Test Task",
            taskDescription: "Test",
            providerId: "test",
            modelId: "test"
        ),
        missingAttachments: [
            AttachmentInfo(originalPath: "/Users/test/Documents/missing-file.pdf", copiedPath: nil, fileSize: 1024),
            AttachmentInfo(originalPath: "/Users/test/Desktop/another-file.docx", copiedPath: nil, fileSize: 2048)
        ],
        validAttachments: [
            AttachmentInfo(originalPath: "/Users/test/existing-file.txt", copiedPath: nil, fileSize: 512)
        ],
        onConfirm: { _ in },
        onCancel: { }
    )
}
