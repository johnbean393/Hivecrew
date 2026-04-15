//
//  TranscriptView.swift
//  Hivelink
//
//  Scrollable chat-bubble transcript for voice calls.
//

import QuickLook
import SwiftUI

struct TranscriptView: View {
    let entries: [TranscriptEntry]

    private var scrollAnchorId: String { "transcript-bottom" }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(entries) { entry in
                        TranscriptBubble(entry: entry)
                            .id(entry.id)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(scrollAnchorId)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .onChange(of: entries.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: entries.last?.text) { _, _ in
                scrollToBottom(proxy)
            }
            .onAppear {
                scrollToBottom(proxy)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(scrollAnchorId, anchor: .bottom)
        }
    }
}

// MARK: - Bubble

private struct TranscriptBubble: View {
    let entry: TranscriptEntry

    var body: some View {
        switch entry.content {
        case .deliverables(let workerName, let filePaths):
            DeliverablePreviewBubble(workerName: workerName, filePaths: filePaths)
        default:
            switch entry.role {
            case .user:
                userBubble
            case .model:
                modelBubble
            case .tool:
                toolPill
            }
        }
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 60)
            Text(entry.text)
                .font(.body)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.blue, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var modelBubble: some View {
        HStack {
            Text(entry.text)
                .font(.body)
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    Color(.systemGray5),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
            Spacer(minLength: 60)
        }
    }

    private var toolPill: some View {
        HStack {
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "wrench.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(entry.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                Color(.systemGray6),
                in: Capsule()
            )
            Spacer()
        }
    }
}

// MARK: - Deliverable Preview

private struct DeliverablePreviewBubble: View {
    let workerName: String
    let filePaths: [String]

    @State private var selectedIndex = 0
    @State private var fullScreenURL: URL?

    private var urls: [URL] {
        filePaths.map { URL(fileURLWithPath: $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerLabel

            if !urls.isEmpty {
                let safeIndex = min(selectedIndex, max(0, urls.count - 1))
                QuickLookPreview(url: urls[safeIndex])
                    .id(urls[safeIndex])
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .onTapGesture {
                        fullScreenURL = urls[safeIndex]
                    }
            }

            if urls.count > 1 {
                fileTabBar
            } else if let url = urls.first {
                singleFileLabel(url)
            }
        }
        .padding(10)
        .background(
            Color(.systemGray6),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .fullScreenCover(item: $fullScreenURL) { url in
            FullScreenQuickLook(urls: urls, initialIndex: selectedIndex)
                .ignoresSafeArea()
        }
    }

    private var headerLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.fill")
                .font(.caption)
                .foregroundStyle(.blue)
            Text("\(workerName) — \(urls.count) deliverable\(urls.count == 1 ? "" : "s")")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.bottom, 8)
    }

    private func singleFileLabel(_ url: URL) -> some View {
        HStack(spacing: 6) {
            Image(systemName: iconName(for: url))
                .font(.caption2)
                .foregroundStyle(.blue)
            Text(url.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.top, 8)
    }

    private var fileTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                    fileTab(url: url, index: index)
                }
            }
            .padding(.top, 8)
        }
    }

    private func fileTab(url: URL, index: Int) -> some View {
        let isSelected = index == selectedIndex
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedIndex = index
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: iconName(for: url))
                    .font(.system(size: 9))
                Text(url.lastPathComponent)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                isSelected
                    ? AnyShapeStyle(.blue.opacity(0.18))
                    : AnyShapeStyle(Color(.systemGray5)),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .strokeBorder(isSelected ? Color.blue.opacity(0.5) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? .blue : .secondary)
    }

    private func iconName(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf": return "doc.richtext"
        case "png", "jpg", "jpeg", "heic", "webp", "gif": return "photo"
        case "txt", "md", "csv", "json": return "doc.text"
        case "html", "htm": return "globe"
        case "xlsx", "xls": return "tablecells"
        case "docx", "doc": return "doc.fill"
        case "zip", "tar", "gz": return "archivebox"
        default: return "doc"
        }
    }
}

// MARK: - Full-Screen Quick Look

private struct FullScreenQuickLook: UIViewControllerRepresentable {
    let urls: [URL]
    let initialIndex: Int

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.currentPreviewItemIndex = initialIndex
        let nav = UINavigationController(rootViewController: controller)
        return nav
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {
        context.coordinator.urls = urls
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(urls: urls)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var urls: [URL]

        init(urls: [URL]) {
            self.urls = urls
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            urls.count
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            urls[index] as NSURL
        }
    }
}

#Preview {
    TranscriptView(entries: [
        .speech(role: .user, text: "Create a landing page for my app"),
        .speech(role: .model, text: "On it — I've assigned Alex to build a landing page for your app."),
        .toolUse(ToolUseRecord(
            toolName: "create_task",
            summary: "Assigned Alex — Landing Page",
            detail: "Task created",
            fileResults: []
        )),
        .speech(role: .user, text: "How's it going?"),
        .speech(role: .model, text: "Alex is about halfway done — they've finished the hero section and navigation."),
    ])
}
