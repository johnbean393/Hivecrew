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

final class ChipScrollGestureGate: ObservableObject {
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

func revealFileInFinder(_ url: URL) {
    let fileURL = url.standardizedFileURL
    if FileManager.default.fileExists(atPath: fileURL.path) {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    } else {
        NSWorkspace.shared.open(fileURL.deletingLastPathComponent())
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
