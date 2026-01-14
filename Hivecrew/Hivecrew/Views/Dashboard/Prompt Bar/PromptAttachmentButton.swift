//
//  PromptAttachmentButton.swift
//  Hivecrew
//
//  Button for adding file attachments to the prompt bar
//

import Combine
import SwiftUI
import UniformTypeIdentifiers

/// A button that opens a file picker to select attachments
struct PromptAttachmentButton: View {
    
    var onFilesSelected: ([URL]) async -> Void
    
    @State private var showingFilePicker: Bool = false
    
    var body: some View {
        Button {
            showingFilePicker = true
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("a", modifiers: [.command, .shift])
        .help("Attach files (⌘⇧A)")
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                Task { @MainActor in
                    await onFilesSelected(urls)
                }
            }
        }
    }
}

#Preview {
    PromptAttachmentButton { urls in
        print("Selected: \(urls)")
    }
    .padding()
}
