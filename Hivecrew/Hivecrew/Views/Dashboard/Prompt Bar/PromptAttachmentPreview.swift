//
//  PromptAttachmentPreview.swift
//  Hivecrew
//
//  Visual previews for attached files in the prompt bar
//

import Combine
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
    @StateObject private var scrollGestureGate = ChipScrollGestureGate()
    
    private let ghostAttachmentsTip = GhostContextAttachmentsTip()
    private let chipSpring = Animation.spring(response: 0.28, dampingFraction: 0.82)
    
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
                        scrollGestureGate: scrollGestureGate,
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
                    .transition(chipTransition)
                }

                ForEach(ghostSuggestions) { suggestion in
                    if let url = ghostURL(for: suggestion) {
                        PromptGhostAttachmentPreviewItem(
                            fileURL: url,
                            scrollGestureGate: scrollGestureGate,
                            onOpen: {
                                onOpenAttachment?(url)
                            },
                            onPromote: {
                                onPromoteGhostSuggestion?(suggestion)
                            }
                        )
                        .transition(chipTransition)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .animation(chipSpring, value: attachments.map(\.id))
        .animation(chipSpring, value: ghostSuggestions.map(\.id))
    }

    private var chipTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.96)),
            removal: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.96))
        )
    }

    private func ghostURL(for suggestion: PromptContextSuggestion) -> URL? {
        let path = suggestion.sourcePathOrHandle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }
}

private final class ChipScrollGestureGate: ObservableObject {
    private var isLocked = false
    private var lockExpiresAt: Date = .distantPast

    func shouldConsume(_ event: NSEvent, now: Date = Date()) -> Bool {
        guard isLocked else { return false }

        if event.phase == .ended || event.momentumPhase == .ended || now >= lockExpiresAt {
            isLocked = false
            return false
        }
        return true
    }

    func lock(now: Date = Date(), minimumDuration: TimeInterval = 0.9) {
        isLocked = true
        lockExpiresAt = now.addingTimeInterval(minimumDuration)
    }
}

/// Suggested context shown as a ghost attachment chip.
struct PromptGhostAttachmentPreviewItem: View {
    let fileURL: URL
    fileprivate let scrollGestureGate: ChipScrollGestureGate
    var onOpen: () -> Void
    var onPromote: () -> Void

    @State private var thumbnail: NSImage?
    @State private var isHovering = false
    @State private var scrollMonitor: Any?
    @State private var accumulatedScrollY: CGFloat = 0

    private let thumbnailSize: CGFloat = 48
    private let containerHeight: CGFloat = 48
    private let cornerRadius: CGFloat = 10
    private let actionSegmentWidth: CGFloat = 34
    private let scrollThreshold: CGFloat = 30
    private let verticalIntentRatio: CGFloat = 1.35

    var body: some View {
        HStack(spacing: 0) {
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
                .frame(height: containerHeight)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
            }
            .buttonStyle(.plain)

            if isHovering {
                Button(action: onPromote) {
                    ZStack {
                        Color.accentColor.opacity(0.95)
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: actionSegmentWidth, height: containerHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.white.opacity(0.28))
                        .frame(width: 1)
                }
                .help("Attach suggested context")
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .opacity(0.6)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .onAppear {
            loadThumbnail()
            setupScrollMonitor()
        }
        .onDisappear {
            removeScrollMonitor()
        }
        .help("Suggested context: click to preview, + or scroll to attach")
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

    private func setupScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { event in
            handleScroll(event)
        }
    }

    private func removeScrollMonitor() {
        guard let scrollMonitor else { return }
        NSEvent.removeMonitor(scrollMonitor)
        self.scrollMonitor = nil
    }

    private func handleScroll(_ event: NSEvent) -> NSEvent? {
        guard isHovering else { return event }
        let now = Date()

        if scrollGestureGate.shouldConsume(event, now: now) {
            return nil
        }

        if event.phase == .began || event.momentumPhase == .began {
            accumulatedScrollY = 0
        }

        let deltaX = abs(event.scrollingDeltaX)
        let deltaY = abs(event.scrollingDeltaY)
        guard deltaY >= deltaX * verticalIntentRatio else {
            accumulatedScrollY = 0
            return event
        }

        accumulatedScrollY += event.scrollingDeltaY

        if abs(accumulatedScrollY) >= scrollThreshold {
            accumulatedScrollY = 0
            scrollGestureGate.lock(now: now)
            onPromote()
            return nil
        }

        if event.phase == .ended || event.momentumPhase == .ended {
            accumulatedScrollY = 0
        }

        return event
    }
}

/// Individual attachment preview item
struct PromptAttachmentPreviewItem: View {
    
    let attachment: PromptAttachment
    fileprivate let scrollGestureGate: ChipScrollGestureGate
    var onOpen: () -> Void
    var onRemove: () -> Void
    
    @State private var thumbnail: NSImage?
    @State private var isHovering: Bool = false
    @State private var scrollMonitor: Any?
    @State private var accumulatedScrollY: CGFloat = 0
    
    private let thumbnailSize: CGFloat = 48
    private let containerHeight: CGFloat = 48
    private let cornerRadius: CGFloat = 10
    private let actionSegmentWidth: CGFloat = 34
    private let scrollThreshold: CGFloat = 30
    private let verticalIntentRatio: CGFloat = 1.35
    
    var body: some View {
        HStack(spacing: 0) {
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
                    
                    Text(attachment.fileName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: 120, alignment: .leading)
                }
                .frame(height: containerHeight)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
            }
            .buttonStyle(.plain)
            
            if isHovering {
                Button(action: onRemove) {
                    ZStack {
                        Color.red.opacity(0.9)
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: actionSegmentWidth, height: containerHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.white.opacity(0.28))
                        .frame(width: 1)
                }
                .help("Remove attachment")
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .onAppear {
            loadThumbnail()
            setupScrollMonitor()
        }
        .onDisappear {
            removeScrollMonitor()
        }
        .help("Attachment: click to preview, x or scroll to remove")
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

    private func setupScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { event in
            handleScroll(event)
        }
    }

    private func removeScrollMonitor() {
        guard let scrollMonitor else { return }
        NSEvent.removeMonitor(scrollMonitor)
        self.scrollMonitor = nil
    }

    private func handleScroll(_ event: NSEvent) -> NSEvent? {
        guard isHovering else { return event }
        let now = Date()

        if scrollGestureGate.shouldConsume(event, now: now) {
            return nil
        }

        if event.phase == .began || event.momentumPhase == .began {
            accumulatedScrollY = 0
        }

        let deltaX = abs(event.scrollingDeltaX)
        let deltaY = abs(event.scrollingDeltaY)
        guard deltaY >= deltaX * verticalIntentRatio else {
            accumulatedScrollY = 0
            return event
        }

        accumulatedScrollY += event.scrollingDeltaY

        if abs(accumulatedScrollY) >= scrollThreshold {
            accumulatedScrollY = 0
            scrollGestureGate.lock(now: now)
            onRemove()
            return nil
        }

        if event.phase == .ended || event.momentumPhase == .ended {
            accumulatedScrollY = 0
        }

        return event
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
