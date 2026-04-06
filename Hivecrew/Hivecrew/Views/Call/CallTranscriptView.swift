//
//  CallTranscriptView.swift
//  Hivecrew
//
//  Scrolling transcript view with gradient fade mask.
//  Renders speech turns and inline tool-use records (e.g. file search results).
//

import SwiftUI
import QuickLookThumbnailing

struct CallTranscriptView: View {

    @Binding var entries: [TranscriptEntry]
    var assistantName: String = "Hivecrew"

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(entries) { entry in
                            transcriptRow(for: entry)
                                .id(entry.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(width: geo.size.width, alignment: .leading)
                    .frame(minHeight: geo.size.height)
                }
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.1),
                            .init(color: .black, location: 0.9),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .onChange(of: entries.count) {
                    if let last = entries.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func transcriptRow(for entry: TranscriptEntry) -> some View {
        switch entry.content {
        case .text(let text):
            HStack(alignment: .top, spacing: 8) {
                Text(entry.role == .user ? "You" : assistantName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(entry.role == .user ? .blue : .secondary)
                    .frame(width: 64, alignment: .trailing)

                Text(text)
                    .font(.system(size: 14))
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
            }

        case .toolUse(let record):
            TranscriptToolUseView(entries: $entries, entryId: entry.id, record: record)
        }
    }
}

// MARK: - Inline Tool Use View

/// Renders a tool-use record inline in the transcript.
/// Currently handles search_files with file card chips; extensible for other tools.
struct TranscriptToolUseView: View {

    @Binding var entries: [TranscriptEntry]
    let entryId: UUID
    let record: ToolUseRecord

    @State private var isExpanded = false
    @StateObject private var scrollGestureGate = ChipScrollGestureGate()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                guard hasExpandableDetail else { return }
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: iconForTool)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(record.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if hasExpandableDetail {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.leading, 72)

            if isExpanded, hasExpandableDetail {
                Text(record.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .padding(.leading, 72)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if let path = record.previewFilePath {
                FilePreviewThumbnail(path: path, onTap: {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                })
                .padding(.leading, 72)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }

            if !record.fileResults.isEmpty {
                fileResultChips
            }
        }
    }

    private var hasExpandableDetail: Bool {
        !record.detail.isEmpty
            && record.toolName != "search_files"
            && record.previewFilePath == nil
    }

    private var iconForTool: String {
        switch record.toolName {
        case "create_task":          return "plus.circle.fill"
        case "get_task_status":      return "info.circle.fill"
        case "send_instruction":     return "arrow.up.message.fill"
        case "pause_task":           return "pause.circle.fill"
        case "resume_task":          return "play.circle.fill"
        case "cancel_task":          return "xmark.circle.fill"
        case "capture_reference":    return "camera.fill"
        case "search_files":         return "doc.text.magnifyingglass"
        case "get_deliverables":     return "doc.on.doc.fill"
        case "focus_task":           return "scope"
        case "end_call":             return "phone.down.fill"
        case "read_file":            return "doc.text.fill"
        case "search_file_content":  return "text.magnifyingglass"
        case "open_file":            return "arrow.up.forward.app.fill"
        default:                     return "wrench.fill"
        }
    }

    private var fileResultChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(record.fileResults) { result in
                    if result.isSelected, let url = fileURL(for: result) {
                        PromptGhostAttachmentPreviewItem(
                            fileURL: url,
                            scrollGestureGate: scrollGestureGate,
                            onOpen: {
                                revealFileInFinder(url)
                            },
                            onPromote: {
                                deselectResult(result.id)
                            }
                        )
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.96)),
                            removal: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.96))
                        ))
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .padding(.leading, 72)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: record.fileResults.map(\.isSelected))
    }

    private func fileURL(for result: VoiceFileSearchResult) -> URL? {
        let path = result.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func deselectResult(_ resultId: String) {
        guard let entryIndex = entries.firstIndex(where: { $0.id == entryId }),
              case .toolUse(var record) = entries[entryIndex].content,
              let resultIndex = record.fileResults.firstIndex(where: { $0.id == resultId }) else { return }
        record.fileResults[resultIndex].isSelected = false
        entries[entryIndex] = .toolUse(record, timestamp: entries[entryIndex].timestamp)
    }
}

// MARK: - File Preview Thumbnail

/// Generates a QuickLook thumbnail for any file type. Falls back to NSImage for
/// common image formats, and to NSWorkspace file icon if thumbnail generation fails.
private struct FilePreviewThumbnail: View {

    let path: String
    var onTap: () -> Void = {}

    @State private var thumbnail: NSImage?

    private var url: URL { URL(fileURLWithPath: path) }

    var body: some View {
        HStack {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            }
            .frame(maxHeight: 100)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onTapGesture(perform: onTap)
            Spacer()
        }
        .task { await generateThumbnail() }
    }

    private func generateThumbnail() async {
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "bmp"]
        if imageExts.contains(url.pathExtension.lowercased()),
           let nsImage = NSImage(contentsOf: url) {
            thumbnail = nsImage
            return
        }

        let size = CGSize(width: 300, height: 300)
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: NSScreen.main?.backingScaleFactor ?? 2.0,
            representationTypes: .thumbnail
        )

        do {
            let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            thumbnail = representation.nsImage
        } catch {
            thumbnail = NSWorkspace.shared.icon(forFile: path)
        }
    }
}
