import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

struct PromptGhostAttachmentPreviewItem: View {
    let fileURL: URL
    let scrollGestureGate: ChipScrollGestureGate
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
        .contextMenu {
            Button {
                revealFileInFinder(fileURL)
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
        }
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
        promptAttachmentIcon(forPathExtension: fileURL.pathExtension)
    }

    private func loadThumbnail() {
        loadPromptAttachmentThumbnail(for: fileURL, size: thumbnailSize) { thumbnail in
            self.thumbnail = thumbnail
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
        handleChipScroll(
            event,
            isHovering: isHovering,
            accumulatedScrollY: &accumulatedScrollY,
            scrollGestureGate: scrollGestureGate,
            verticalIntentRatio: verticalIntentRatio,
            scrollThreshold: scrollThreshold,
            action: onPromote
        )
    }
}

struct PromptAttachmentPreviewItem: View {
    let attachment: PromptAttachment
    let scrollGestureGate: ChipScrollGestureGate
    var onOpen: () -> Void
    var onRemove: () -> Void

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
            .contextMenu {
                Button {
                    revealFileInFinder(attachment.url)
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
            }

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
                .contextMenu {
                    Button {
                        revealFileInFinder(attachment.url)
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                }
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
        promptAttachmentIcon(forPathExtension: attachment.url.pathExtension)
    }

    private func loadThumbnail() {
        loadPromptAttachmentThumbnail(for: attachment.url, size: thumbnailSize) { thumbnail in
            self.thumbnail = thumbnail
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
        handleChipScroll(
            event,
            isHovering: isHovering,
            accumulatedScrollY: &accumulatedScrollY,
            scrollGestureGate: scrollGestureGate,
            verticalIntentRatio: verticalIntentRatio,
            scrollThreshold: scrollThreshold,
            action: onRemove
        )
    }
}

private func promptAttachmentIcon(forPathExtension pathExtension: String) -> String {
    guard let uti = UTType(filenameExtension: pathExtension) else {
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

private func loadPromptAttachmentThumbnail(
    for url: URL,
    size: CGFloat,
    assign: @escaping (NSImage?) -> Void
) {
    let request = QLThumbnailGenerator.Request(
        fileAt: url,
        size: CGSize(width: size * 2, height: size * 2),
        scale: NSScreen.main?.backingScaleFactor ?? 2.0,
        representationTypes: .thumbnail
    )

    QLThumbnailGenerator.shared.generateRepresentations(for: request) { representation, _, _ in
        if let representation {
            DispatchQueue.main.async {
                assign(representation.nsImage)
            }
        }
    }
}

private func handleChipScroll(
    _ event: NSEvent,
    isHovering: Bool,
    accumulatedScrollY: inout CGFloat,
    scrollGestureGate: ChipScrollGestureGate,
    verticalIntentRatio: CGFloat,
    scrollThreshold: CGFloat,
    action: () -> Void
) -> NSEvent? {
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
        action()
        return nil
    }

    if event.phase == .ended || event.momentumPhase == .ended {
        accumulatedScrollY = 0
    }

    return event
}
