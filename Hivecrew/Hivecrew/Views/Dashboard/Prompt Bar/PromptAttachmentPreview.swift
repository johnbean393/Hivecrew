//
//  PromptAttachmentPreview.swift
//  Hivecrew
//
//  Visual previews for attached files in the prompt bar
//

import SwiftUI
import UniformTypeIdentifiers
import QuickLookThumbnailing
import TipKit

enum PromptAttachmentOrigin: Equatable {
    case userSelection
    case indexedContext(suggestionID: String)

    var indexedSuggestionID: String? {
        if case .indexedContext(let suggestionID) = self {
            return suggestionID
        }
        return nil
    }
}

/// A model representing an attached file
struct PromptAttachment: Identifiable, Equatable {
    let id: UUID
    let url: URL
    let origin: PromptAttachmentOrigin
    var thumbnail: NSImage?
    
    var fileName: String {
        url.lastPathComponent
    }
    
    var isImage: Bool {
        guard let uti = UTType(filenameExtension: url.pathExtension) else { return false }
        return uti.conforms(to: .image)
    }
    
    init(url: URL, origin: PromptAttachmentOrigin = .userSelection) {
        self.id = UUID()
        self.url = url
        self.origin = origin
        self.thumbnail = nil
    }
    
    static func == (lhs: PromptAttachment, rhs: PromptAttachment) -> Bool {
        lhs.id == rhs.id
    }
}

/// Container view for displaying all attached files
struct PromptAttachmentPreviewList: View {
    
    @Binding var attachments: [PromptAttachment]
    var ghostSuggestions: [PromptContextSuggestion] = []
    var onRemoveAttachment: ((PromptAttachment) -> Void)? = nil
    var onPromoteGhostSuggestion: ((PromptContextSuggestion) -> Void)? = nil
    var onOpenAttachment: ((URL) -> Void)? = nil
    
    private let ghostAttachmentsTip = GhostContextAttachmentsTip()
    
    var body: some View {
        if !attachments.isEmpty || !ghostSuggestions.isEmpty {
            if !ghostSuggestions.isEmpty {
                chipsScrollView
                    .popoverTip(ghostAttachmentsTip, arrowEdge: .top)
            } else {
                chipsScrollView
            }
        }
    }

    private var chipsScrollView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    PromptAttachmentPreviewItem(
                        attachment: attachment,
                        onOpen: {
                            onOpenAttachment?(attachment.url)
                        },
                        onRemove: {
                            withAnimation(.easeOut(duration: 0.2)) {
                                attachments.removeAll { $0.id == attachment.id }
                            }
                            onRemoveAttachment?(attachment)
                        }
                    )
                }

                ForEach(ghostSuggestions) { suggestion in
                    if let url = ghostURL(for: suggestion) {
                        PromptGhostAttachmentPreviewItem(
                            fileURL: url,
                            onOpen: {
                                onOpenAttachment?(url)
                            },
                            onPromote: {
                                onPromoteGhostSuggestion?(suggestion)
                            }
                        )
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func ghostURL(for suggestion: PromptContextSuggestion) -> URL? {
        let path = suggestion.sourcePathOrHandle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }
}

/// Suggested context shown as a ghost attachment chip.
struct PromptGhostAttachmentPreviewItem: View {
    let fileURL: URL
    var onOpen: () -> Void
    var onPromote: () -> Void

    @State private var thumbnail: NSImage?
    @State private var isHovering = false

    private let thumbnailSize: CGFloat = 48
    private let containerHeight: CGFloat = 48
    private let cornerRadius: CGFloat = 10

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onOpen) {
                HStack(spacing: 0) {
                    thumbnailView
                        .frame(width: thumbnailSize, height: containerHeight)
                        .clipShape(
                            UnevenRoundedRectangle(
                                topLeadingRadius: cornerRadius,
                                bottomLeadingRadius: cornerRadius,
                                bottomTrailingRadius: 0,
                                topTrailingRadius: 0
                            )
                        )

                    Text(fileURL.lastPathComponent)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: 120, alignment: .leading)
                }
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .opacity(0.6)
            }
            .buttonStyle(.plain)

            if isHovering {
                Button(action: onPromote) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.white, Color.accentColor)
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .onAppear {
            loadThumbnail()
        }
        .help("Suggested context: click to preview, + to attach")
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color(nsColor: .separatorColor).opacity(0.3)
                Image(systemName: iconForFile)
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var iconForFile: String {
        guard let uti = UTType(filenameExtension: fileURL.pathExtension) else {
            return "doc"
        }

        if uti.conforms(to: .image) {
            return "photo"
        } else if uti.conforms(to: .pdf) {
            return "doc.richtext"
        } else if uti.conforms(to: .plainText) || uti.conforms(to: .sourceCode) {
            return "doc.text"
        } else if uti.conforms(to: .archive) {
            return "doc.zipper"
        } else if uti.conforms(to: .movie) || uti.conforms(to: .video) {
            return "film"
        } else if uti.conforms(to: .audio) {
            return "waveform"
        } else {
            return "doc"
        }
    }

    private func loadThumbnail() {
        let size = CGSize(width: thumbnailSize * 2, height: thumbnailSize * 2)
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let request = QLThumbnailGenerator.Request(
            fileAt: fileURL,
            size: size,
            scale: scale,
            representationTypes: .thumbnail
        )

        QLThumbnailGenerator.shared.generateRepresentations(for: request) { representation, _, _ in
            if let representation {
                DispatchQueue.main.async {
                    self.thumbnail = representation.nsImage
                }
            }
        }
    }
}

/// Individual attachment preview item
struct PromptAttachmentPreviewItem: View {
    
    let attachment: PromptAttachment
    var onOpen: () -> Void
    var onRemove: () -> Void
    
    @State private var thumbnail: NSImage?
    @State private var isHovering: Bool = false
    
    private let thumbnailSize: CGFloat = 48
    private let containerHeight: CGFloat = 48
    private let cornerRadius: CGFloat = 10
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onOpen) {
                // Main horizontal container
                HStack(spacing: 0) {
                    // LEFT: Thumbnail preview
                    thumbnailView
                        .frame(width: thumbnailSize, height: containerHeight)
                        .clipShape(
                            UnevenRoundedRectangle(
                                topLeadingRadius: cornerRadius,
                                bottomLeadingRadius: cornerRadius,
                                bottomTrailingRadius: 0,
                                topTrailingRadius: 0
                            )
                        )
                    
                    // RIGHT: Filename
                    Text(attachment.fileName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: 120, alignment: .leading)
                }
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            
            // Remove button
            if isHovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.white, .red)
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .onAppear {
            loadThumbnail()
        }
    }
    
    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnail = thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            // Fallback icon based on file type
            ZStack {
                Color(nsColor: .separatorColor).opacity(0.3)
                Image(systemName: iconForFile)
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    private var iconForFile: String {
        guard let uti = UTType(filenameExtension: attachment.url.pathExtension) else {
            return "doc"
        }
        
        if uti.conforms(to: .image) {
            return "photo"
        } else if uti.conforms(to: .pdf) {
            return "doc.richtext"
        } else if uti.conforms(to: .plainText) || uti.conforms(to: .sourceCode) {
            return "doc.text"
        } else if uti.conforms(to: .archive) {
            return "doc.zipper"
        } else if uti.conforms(to: .movie) || uti.conforms(to: .video) {
            return "film"
        } else if uti.conforms(to: .audio) {
            return "waveform"
        } else {
            return "doc"
        }
    }
    
    private func loadThumbnail() {
        let url = attachment.url
        let size = CGSize(width: thumbnailSize * 2, height: thumbnailSize * 2)
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
            representationTypes: .thumbnail
        )
        
        QLThumbnailGenerator.shared.generateRepresentations(for: request) { representation, type, error in
            if let representation = representation {
                DispatchQueue.main.async {
                    self.thumbnail = representation.nsImage
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    struct PreviewWrapper: View {
        @State var attachments: [PromptAttachment] = [
            PromptAttachment(url: URL(fileURLWithPath: "/Users/test/image.png")),
            PromptAttachment(url: URL(fileURLWithPath: "/Users/test/document.pdf")),
            PromptAttachment(url: URL(fileURLWithPath: "/Users/test/code.swift"))
        ]
        
        var body: some View {
            VStack {
                PromptAttachmentPreviewList(attachments: $attachments)
            }
            .frame(width: 400)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
    
    return PreviewWrapper()
}
