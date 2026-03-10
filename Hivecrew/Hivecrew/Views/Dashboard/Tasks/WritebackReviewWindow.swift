//
//  WritebackReviewWindow.swift
//  Hivecrew
//
//  Review staged local filesystem changes before applying them.
//

import SwiftUI
import QuickLook
import QuickLookUI
import AppKit

struct WritebackReviewWindow: View {
    let task: TaskRecord
    @ObservedObject var taskService: TaskService

    @Environment(\.dismiss) private var dismiss

    @State private var review = WritebackReviewPayload(items: [])
    @State private var errorMessage: String?
    @State private var isApplying = false
    @State private var quickLookURL: URL?
    @State private var quickLookURLs: [URL] = []
    @State private var searchText = ""
    @State private var selectedItemID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if review.items.isEmpty {
                ContentUnavailableView(
                    "No Pending Changes",
                    systemImage: "checkmark.circle",
                    description: Text("There are no staged local filesystem changes for this task.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                summaryBar

                Divider()

                HSplitView {
                    sidebar
                        .frame(minWidth: 260, idealWidth: 310, maxWidth: 380)

                    detailPane
                        .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            Divider()

            footer
        }
        .frame(minWidth: 1040, minHeight: 720)
        .task(id: task.pendingWritebackOperations.count) {
            refreshReview()
        }
        .onChange(of: searchText) { _, _ in
            coerceSelection()
        }
        .quickLookPreview($quickLookURL, in: quickLookURLs)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Review Local Changes")
                    .font(.headline)
                Text(task.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if review.hasConflicts {
                Label("Conflicts detected", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.subheadline)
            }
        }
        .padding()
    }

    private var summaryBar: some View {
        HStack(spacing: 20) {
            summaryMetric("\(review.items.count)", label: "changes")
            summaryMetric("\(groupedSections.folderSectionCount)", label: "folders affected")
            summaryMetric("\(groupedSections.deleteTargetCount)", label: "originals removed after apply")

            Spacer()

            Text("Applying will write staged VM changes to local destinations.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func summaryMetric(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.headline)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Changes")
                    .font(.headline)

                TextField("Search changes...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
            }
            .padding()

            Divider()

            List(selection: $selectedItemID) {
                if !groupedSections.conflicts.isEmpty {
                    Section {
                        ForEach(groupedSections.conflicts) { row in
                            sidebarRow(row)
                                .tag(row.id)
                        }
                    } header: {
                        sectionHeader("Conflicts", count: groupedSections.conflicts.count, isWarning: true)
                    }
                }

                ForEach(groupedSections.sections) { section in
                    Section {
                        ForEach(section.rows) { row in
                            sidebarRow(row)
                                .tag(row.id)
                        }
                    } header: {
                        sectionHeader(section.title, count: section.rows.count, isWarning: false)
                    }
                }

                if groupedSections.sections.isEmpty && groupedSections.conflicts.isEmpty {
                    Text("No changes match the current filter.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    private func sectionHeader(_ title: String, count: Int, isWarning: Bool) -> some View {
        HStack(spacing: 6) {
            if isWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Text(title)
            Spacer()
            Text("\(count)")
                .foregroundStyle(.secondary)
        }
        .font(.caption.weight(.semibold))
        .textCase(nil)
    }

    private func sidebarRow(_ row: WritebackReviewRowModel) -> some View {
        HStack(spacing: 10) {
            Image(systemName: row.iconName)
                .foregroundStyle(row.iconColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.title)
                        .font(.callout)
                        .lineLimit(1)

                    if row.hasDeleteTargets {
                        Image(systemName: "trash")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }

                Text(row.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(row.operationLabel)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.15))
                )
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var detailPane: some View {
        ScrollView {
            if let selectedItem {
                VStack(alignment: .leading, spacing: 16) {
                    selectedItemHeader(selectedItem)

                    HStack(spacing: 12) {
                        detailBadge(title: "Operation", value: operationLabel(selectedItem.operation.operationType))
                        detailBadge(title: "Source", value: selectedItem.operation.sourceFileName)
                        detailBadge(title: "Destination", value: selectedItem.destinationExists ? "Existing file" : "New file")
                    }

                    if !selectedItem.operation.deleteOriginalTargets.isEmpty {
                        deleteTargetsCard(selectedItem)
                    }

                    if let conflictReason = selectedItem.conflictReason {
                        Label(conflictReason, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }

                    if shouldShowInlineComparison(for: selectedItem) {
                        inlineComparisonSection(for: selectedItem)
                    } else {
                        metadataDetailSection(for: selectedItem)
                    }
                }
                .padding()
            } else {
                ContentUnavailableView(
                    "No Change Selected",
                    systemImage: "sidebar.left",
                    description: Text("Choose a staged change from the list to review it.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func selectedItemHeader(_ item: WritebackReviewItem) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.operation.title)
                    .font(.title3.weight(.semibold))
                Text(item.operation.destinationPath)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer()

            statusPill(for: item)
        }
    }

    private func deleteTargetsCard(_ item: WritebackReviewItem) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("Deletes After Apply")
                    .font(.subheadline.weight(.semibold))

                Text("\(item.operation.deleteOriginalTargets.count) original local item(s)")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                ForEach(item.operation.deleteOriginalTargets, id: \.path) { target in
                    Text(target.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func inlineComparisonSection(for item: WritebackReviewItem) -> some View {
        let originalURL = URL(fileURLWithPath: item.operation.destinationPath)
        let editedURL = URL(fileURLWithPath: item.operation.stagedArtifactPath)

        return VStack(alignment: .leading, spacing: 12) {
            Text("Original and Edited")
                .font(.headline)

            HStack(alignment: .top, spacing: 14) {
                quickLookComparisonPane(
                    title: "Original",
                    subtitle: originalURL.lastPathComponent,
                    path: originalURL.path,
                    url: originalURL,
                    relatedURLs: [editedURL]
                )

                quickLookComparisonPane(
                    title: "Edited",
                    subtitle: editedURL.lastPathComponent,
                    path: editedURL.path,
                    url: editedURL,
                    relatedURLs: [originalURL]
                )
            }
        }
    }

    private func quickLookComparisonPane(
        title: String,
        subtitle: String,
        path: String,
        url: URL,
        relatedURLs: [URL]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .lineLimit(1)
                Text(path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }

            if canInlinePreview(url: url) {
                InlineQuickLookPreview(url: url)
                    .frame(minHeight: 360)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                quickLookFallbackCard(for: url)
            }

            Button("Open \(title) in QuickLook") {
                openQuickLook(url, alongside: relatedURLs)
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func quickLookFallbackCard(for url: URL) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.richtext")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Inline QuickLook preview unavailable")
                .font(.callout.weight(.medium))
            Text(url.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 360)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func metadataDetailSection(for item: WritebackReviewItem) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Preview")
                    .font(.subheadline.weight(.semibold))

                if item.destinationExists {
                    HStack(spacing: 12) {
                        previewActionCard(
                            title: "Current Destination",
                            subtitle: URL(fileURLWithPath: item.operation.destinationPath).lastPathComponent,
                            buttonTitle: "Open Current"
                        ) {
                            let currentURL = URL(fileURLWithPath: item.operation.destinationPath)
                            openQuickLook(currentURL, alongside: [URL(fileURLWithPath: item.operation.stagedArtifactPath)])
                        }

                        previewActionCard(
                            title: "Staged Result",
                            subtitle: URL(fileURLWithPath: item.operation.stagedArtifactPath).lastPathComponent,
                            buttonTitle: "Open Staged"
                        ) {
                            let stagedURL = URL(fileURLWithPath: item.operation.stagedArtifactPath)
                            let related = item.destinationExists ? [URL(fileURLWithPath: item.operation.destinationPath)] : []
                            openQuickLook(stagedURL, alongside: related)
                        }
                    }
                } else {
                    previewActionCard(
                        title: "Staged Result",
                        subtitle: URL(fileURLWithPath: item.operation.stagedArtifactPath).lastPathComponent,
                        buttonTitle: "Open Staged"
                    ) {
                        let stagedURL = URL(fileURLWithPath: item.operation.stagedArtifactPath)
                        openQuickLook(stagedURL, alongside: [])
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func previewActionCard(
        title: String,
        subtitle: String,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(subtitle)
                .font(.callout)
                .lineLimit(2)

            Button(buttonTitle, action: action)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func detailBadge(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func statusPill(for item: WritebackReviewItem) -> some View {
        Label(
            item.hasConflict ? "Conflict" : "Ready",
            systemImage: item.hasConflict ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
        )
        .font(.caption.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(item.hasConflict ? Color.orange.opacity(0.15) : Color.blue.opacity(0.15))
        )
        .foregroundStyle(item.hasConflict ? .orange : .blue)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Discard Changes") {
                    discardChanges()
                }
                .disabled(isApplying)

                Button("Apply Changes") {
                    applyChanges()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isApplying || review.items.isEmpty || review.hasConflicts)
            }
        }
        .padding()
    }

    private var groupedSections: WritebackReviewGrouping {
        WritebackReviewGrouping(items: review.items, searchText: searchText)
    }

    private var selectedItem: WritebackReviewItem? {
        groupedSections.allRows.first(where: { $0.id == selectedItemID })?.item
    }

    private func refreshReview() {
        review = taskService.writebackReview(for: task)
        errorMessage = nil
        coerceSelection()
    }

    private func coerceSelection() {
        let allRows = groupedSections.allRows
        if let selectedItemID, allRows.contains(where: { $0.id == selectedItemID }) {
            return
        }
        selectedItemID = allRows.first?.id
    }

    private func applyChanges() {
        isApplying = true
        errorMessage = nil

        Task { @MainActor in
            defer { isApplying = false }
            do {
                try taskService.approveWriteback(for: task)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                refreshReview()
            }
        }
    }

    private func discardChanges() {
        isApplying = true
        errorMessage = nil

        Task { @MainActor in
            defer { isApplying = false }
            do {
                try taskService.discardWriteback(for: task)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                refreshReview()
            }
        }
    }

    private func operationLabel(_ operationType: WritebackOperationType) -> String {
        switch operationType {
        case .copy:
            return "Copy"
        case .move:
            return "Move"
        case .replaceFile:
            return "Replace"
        }
    }

    private func shouldShowInlineComparison(for item: WritebackReviewItem) -> Bool {
        guard item.operation.operationType == .replaceFile, item.destinationExists else {
            return false
        }

        let originalURL = URL(fileURLWithPath: item.operation.destinationPath)
        let editedURL = URL(fileURLWithPath: item.operation.stagedArtifactPath)
        return canInlinePreview(url: originalURL) || canInlinePreview(url: editedURL)
    }

    private func canInlinePreview(url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }

        let ext = url.pathExtension.lowercased()
        let unsupported = ["app", "pkg", "dmg"]
        return !unsupported.contains(ext)
    }

    private func openQuickLook(_ primaryURL: URL, alongside relatedURLs: [URL]) {
        var ordered: [URL] = []
        var seenPaths = Set<String>()

        for url in [primaryURL] + relatedURLs {
            let normalizedPath = url.standardizedFileURL.path
            if seenPaths.insert(normalizedPath).inserted {
                ordered.append(url)
            }
        }

        quickLookURLs = ordered
        quickLookURL = primaryURL
    }
}

private struct WritebackReviewGrouping {
    let conflicts: [WritebackReviewRowModel]
    let sections: [WritebackReviewSection]
    let allRows: [WritebackReviewRowModel]
    let folderSectionCount: Int
    let deleteTargetCount: Int

    init(items: [WritebackReviewItem], searchText: String) {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = items.filter { item in
            guard !query.isEmpty else { return true }
            let haystacks = [
                item.operation.title,
                item.operation.destinationPath,
                item.operation.sourceFileName
            ] + item.operation.deleteOriginalTargets.map(\.path)
            return haystacks.contains { $0.lowercased().contains(query) }
        }

        let conflictItems = filtered
            .filter(\.hasConflict)
            .sorted { $0.operation.destinationPath.localizedCaseInsensitiveCompare($1.operation.destinationPath) == .orderedAscending }

        conflicts = conflictItems.map { WritebackReviewRowModel(item: $0) }

        let nonConflictItems = filtered.filter { !$0.hasConflict }
        let grouped = Dictionary(grouping: nonConflictItems) { item in
            URL(fileURLWithPath: item.operation.destinationPath).deletingLastPathComponent().lastPathComponent
        }

        var builtSections: [WritebackReviewSection] = []
        for (key, value) in grouped {
            let sortedItems = value.sorted {
                $0.operation.destinationPath.localizedCaseInsensitiveCompare($1.operation.destinationPath) == .orderedAscending
            }
            let rows = sortedItems.map { WritebackReviewRowModel(item: $0) }
            builtSections.append(
                WritebackReviewSection(
                    title: key.isEmpty ? "Root" : key,
                    rows: rows
                )
            )
        }
        builtSections.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        sections = builtSections
        allRows = conflicts + sections.flatMap(\.rows)
        folderSectionCount = Set(filtered.map {
            URL(fileURLWithPath: $0.operation.destinationPath).deletingLastPathComponent().path
        }).count
        deleteTargetCount = filtered.reduce(0) { $0 + $1.operation.deleteOriginalTargets.count }
    }
}

private struct WritebackReviewSection: Identifiable {
    let id = UUID()
    let title: String
    let rows: [WritebackReviewRowModel]
}

private struct WritebackReviewRowModel: Identifiable {
    let item: WritebackReviewItem

    var id: UUID { item.id }
    var title: String { URL(fileURLWithPath: item.operation.destinationPath).lastPathComponent }
    var subtitle: String { item.hasConflict ? (item.conflictReason ?? "Conflict") : item.operation.sourceFileName }
    var operationLabel: String {
        switch item.operation.operationType {
        case .copy:
            return "Copy"
        case .move:
            return "Move"
        case .replaceFile:
            return "Replace"
        }
    }
    var hasDeleteTargets: Bool { !item.operation.deleteOriginalTargets.isEmpty }
    var iconName: String {
        if item.hasConflict {
            return "exclamationmark.triangle.fill"
        }
        switch item.operation.operationType {
        case .copy:
            return item.destinationExists ? "doc.on.doc" : "doc.badge.plus"
        case .move:
            return "arrow.right.doc.on.clipboard"
        case .replaceFile:
            return "pencil.and.scribble"
        }
    }
    var iconColor: Color {
        item.hasConflict ? .orange : .accentColor
    }
}

private struct InlineQuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        guard let preview = QLPreviewView(frame: .zero, style: .normal) else {
            return container
        }
        preview.autostarts = true
        preview.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            preview.topAnchor.constraint(equalTo: container.topAnchor),
            preview.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        context.coordinator.previewView = preview
        updatePreview(preview)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let preview = context.coordinator.previewView {
            updatePreview(preview)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    private func updatePreview(_ preview: QLPreviewView) {
        preview.previewItem = url as NSURL
        preview.refreshPreviewItem()
    }

    final class Coordinator {
        var previewView: QLPreviewView?
    }
}
