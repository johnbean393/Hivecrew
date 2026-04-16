//
//  CompletedTaskDetailView.swift
//  Hivelink
//
//  Responsive detail view for terminal tasks.
//

import HivecrewCore
import HivecrewShared
import QuickLook
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Tab model

enum CompletedDetailTab: String, CaseIterable, Identifiable {
    case trace = "Trace"
    case deliverables = "Deliverables"

    var id: String { rawValue }
}

// MARK: - View

struct CompletedTaskDetailView: View {
    let task: TaskRecord

    @Environment(\.dismiss) private var dismiss

    @EnvironmentObject private var artifactCoordinator: ArtifactImportCoordinator
    @EnvironmentObject private var taskService: HivelinkTaskService

    @State private var traceEvents: [TraceEventInfo] = []
    @State private var visibleScreenshotPath: String?
    @State private var selectedTab: CompletedDetailTab = .trace
    @State private var showFullScreenshot = false
    @State private var isImporting = false
    @State private var importFailed = false
    @State private var bulkExportFolderURL: URL?
    @State private var bulkShareFolderURL: URL?
    @State private var bulkActionErrorMessage: String?

    private var hasTrace: Bool { artifactCoordinator.hasImportedTrace(for: task) }
    private var hasDeliverables: Bool {
        !deliverableURLs.isEmpty
    }
    private var deliverableURLs: [URL] {
        (task.outputFilePaths ?? [])
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map(URL.init(fileURLWithPath:))
    }

    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height

            Group {
                if isLandscape {
                    HStack(spacing: 0) {
                        screenshotPane(expandToFillHeight: true)
                            .frame(width: geometry.size.width * 0.46)

                        Divider()

                        ScrollView {
                            detailPane
                        }
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            screenshotPane(expandToFillHeight: false)
                            detailPane
                        }
                    }
                }
            }
        }
        .background(Color(.systemGroupedBackground))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        NotificationCenter.default.post(
                            name: .loadTaskIntoPromptBar,
                            object: nil,
                            userInfo: ["taskId": task.id]
                        )
                        dismiss()
                    } label: {
                        Label(String(localized: "Edit and Rerun"), systemImage: "pencil.and.list.clipboard")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .fullScreenCover(isPresented: $showFullScreenshot) {
            fullScreenScreenshotView
        }
        .sheet(item: $bulkExportFolderURL) { folderURL in
            DocumentExporterView(sourceURL: folderURL)
        }
        .sheet(item: $bulkShareFolderURL) { folderURL in
            ActivityShareView(activityItems: [folderURL])
        }
        .alert("Couldn’t Prepare Deliverables Folder", isPresented: bulkActionErrorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(bulkActionErrorMessage ?? "An unknown error occurred.")
        }
        .onAppear {
            loadTraceIfAvailable()
        }
        .onChange(of: task.sessionId) { _, _ in
            loadTraceIfAvailable()
        }
    }

    // MARK: - Screenshot section

    @ViewBuilder
    private func screenshotPane(expandToFillHeight: Bool) -> some View {
        screenshotSection(expandToFillHeight: expandToFillHeight)
            .frame(maxWidth: .infinity, maxHeight: expandToFillHeight ? .infinity : nil)
    }

    private var detailPane: some View {
        VStack(spacing: 0) {
            headerSection
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

            tabPicker
                .padding(.horizontal, 16)
                .padding(.bottom, 4)

            Divider()

            tabContent
        }
    }

    @ViewBuilder
    private func screenshotSection(expandToFillHeight: Bool) -> some View {
        if let path = visibleScreenshotPath,
           let image = UIImage(contentsOfFile: path) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: expandToFillHeight ? .infinity : nil)
                .background(Color.black)
                .onTapGesture { showFullScreenshot = true }
        } else if isImporting {
            importingPlaceholder(expandToFillHeight: expandToFillHeight)
        } else if !hasTrace {
            downloadPrompt(expandToFillHeight: expandToFillHeight)
        }
    }

    private func importingPlaceholder(expandToFillHeight: Bool) -> some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            Text("Downloading trace…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: expandToFillHeight ? .infinity : nil)
        .frame(height: expandToFillHeight ? nil : 180)
        .background(Color(.secondarySystemBackground))
    }

    private func downloadPrompt(expandToFillHeight: Bool) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Trace not downloaded")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                triggerOnDemandImport()
            } label: {
                Label("Download Trace", systemImage: "arrow.down.to.line")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            if importFailed {
                Text(artifactCoordinator.lastImportError ?? "Import failed. The peer may be offline.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: expandToFillHeight ? .infinity : nil)
        .frame(height: expandToFillHeight ? nil : 200)
        .background(Color(.secondarySystemBackground))
    }

    // MARK: - Full-screen screenshot

    private var fullScreenScreenshotView: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let path = visibleScreenshotPath,
                   let image = UIImage(contentsOfFile: path) {
                    ScrollView([.horizontal, .vertical], showsIndicators: false) {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: UIScreen.main.bounds.width * 2)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showFullScreenshot = false } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.white)
                    }
                }
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: statusIconName)
                    .font(.title2)
                    .foregroundStyle(statusColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(task.status.displayName)
                        .font(.headline)
                    if let peer = task.clusterPeerName, !peer.isEmpty {
                        Text("on \(peer)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(formattedDuration)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if totalTokens > 0 {
                        Text("\(totalTokens) tokens")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            modelPill

            if let summary = task.resultSummary, !summary.isEmpty {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = task.errorMessage, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var modelPill: some View {
        HStack(spacing: 6) {
            let providerName = taskService.getProviderName(for: task.providerId)
            Text(providerName)
                .font(.caption2.weight(.medium))
            Text("·")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(task.modelId)
                .font(.caption2)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
    }

    // MARK: - Tab picker

    private var tabPicker: some View {
        Picker("", selection: $selectedTab) {
            Text("Trace").tag(CompletedDetailTab.trace)
            Text("Deliverables").tag(CompletedDetailTab.deliverables)
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Tab content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .trace:
            traceContent
        case .deliverables:
            deliverablesContent
        }
    }

    // MARK: - Trace content

    @ViewBuilder
    private var traceContent: some View {
        if traceEvents.isEmpty && !hasTrace {
            ContentUnavailableView {
                Label("No Trace", systemImage: "doc.text.magnifyingglass")
            } description: {
                if isImporting {
                    Text("Downloading…")
                } else {
                    Text("Download the trace to see the activity timeline.")
                }
            } actions: {
                if !isImporting {
                    Button {
                        triggerOnDemandImport()
                    } label: {
                        Label("Download Trace", systemImage: "arrow.down.to.line")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .frame(minHeight: 260)
        } else if traceEvents.isEmpty {
            ContentUnavailableView(
                "No Events",
                systemImage: "text.line.first.and.arrowtriangle.forward",
                description: Text("The trace file contains no events.")
            )
            .frame(minHeight: 260)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(Array(traceEvents.enumerated()), id: \.element.id) { idx, event in
                    HistoricalTraceEventRow(event: event, index: idx)
                    if idx < traceEvents.count - 1 {
                        Divider().padding(.leading, 44)
                    }
                }
            }
        }
    }

    // MARK: - Deliverables content

    @ViewBuilder
    private var deliverablesContent: some View {
        if hasDeliverables {
            VStack(spacing: 0) {
                bulkDeliverableActions

                Divider()

                ForEach(Array(deliverableURLs.enumerated()), id: \.element) { index, url in
                    DeliverableDisclosureRow(path: url.path)
                    if index < deliverableURLs.count - 1 {
                        Divider().padding(.leading, 52)
                    }
                }
            }
        } else {
            ContentUnavailableView(
                "No Deliverables",
                systemImage: "tray",
                description: Text("This task produced no output files.")
            )
            .frame(minHeight: 260)
        }
    }

    private var bulkDeliverableActions: some View {
        HStack(spacing: 12) {
            Button {
                exportAllDeliverables()
            } label: {
                Label("Save All", systemImage: "square.and.arrow.down")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                shareAllDeliverables()
            } label: {
                Label("Share All", systemImage: "square.and.arrow.up")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
    }

    // MARK: - Actions

    private func loadTraceIfAvailable() {
        guard let sessionDir = artifactCoordinator.sessionDirectoryURL(for: task) else { return }
        let traceFile = sessionDir.appendingPathComponent("trace.jsonl")
        guard let content = try? String(contentsOf: traceFile, encoding: .utf8) else { return }
        traceEvents = SessionTraceParser.parseEvents(from: content, sessionDirectory: sessionDir)

        if let first = traceEvents.last(where: { $0.screenshotPath != nil }) {
            visibleScreenshotPath = first.screenshotPath
        }
    }

    private func triggerOnDemandImport() {
        guard !isImporting else { return }
        isImporting = true
        importFailed = false

        Task {
            let success = await artifactCoordinator.importOnDemand(
                task: task,
                peerClient: { peer in await taskService.dispatcher.peerClient(for: peer) },
                peerLookup: { id in await taskService.clusterCoordinator?.peer(id: id) },
                remoteTaskIndex: taskService.remoteTaskIndex,
                saveContext: { try taskService.saveModelContext() }
            )

            isImporting = false
            if success {
                loadTraceIfAvailable()
            } else {
                importFailed = true
            }
        }
    }

    private var bulkActionErrorPresented: Binding<Bool> {
        Binding(
            get: { bulkActionErrorMessage != nil },
            set: { if !$0 { bulkActionErrorMessage = nil } }
        )
    }

    private func exportAllDeliverables() {
        do {
            bulkExportFolderURL = try makeBulkDeliverablesFolder()
        } catch {
            bulkActionErrorMessage = error.localizedDescription
        }
    }

    private func shareAllDeliverables() {
        do {
            bulkShareFolderURL = try makeBulkDeliverablesFolder()
        } catch {
            bulkActionErrorMessage = error.localizedDescription
        }
    }

    private func makeBulkDeliverablesFolder() throws -> URL {
        guard !deliverableURLs.isEmpty else {
            throw BulkDeliverablesFolderError.noDeliverables
        }

        let fileManager = FileManager.default
        let parentDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "HivelinkDeliverables",
            isDirectory: true
        )
        try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)

        let folderURL = parentDirectory.appendingPathComponent(bulkFolderName, isDirectory: true)
        if fileManager.fileExists(atPath: folderURL.path) {
            try fileManager.removeItem(at: folderURL)
        }
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)

        var copiedCount = 0
        for sourceURL in deliverableURLs where fileManager.fileExists(atPath: sourceURL.path) {
            let destinationURL = uniqueDestinationURL(
                for: sourceURL.lastPathComponent,
                in: folderURL,
                fileManager: fileManager
            )
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            copiedCount += 1
        }

        guard copiedCount > 0 else {
            throw BulkDeliverablesFolderError.noReadableDeliverables
        }

        return folderURL
    }

    private var bulkFolderName: String {
        "\(sanitizedTaskTitle)_\(Self.bulkFolderTimestampFormatter.string(from: Date()))"
    }

    private var sanitizedTaskTitle: String {
        let invalidCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleanedScalars = task.title.unicodeScalars.map { scalar in
            invalidCharacters.contains(scalar) ? "_" : Character(scalar)
        }
        let cleanedTitle = String(cleanedScalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanedTitle.isEmpty ? "Task" : cleanedTitle
    }

    private func uniqueDestinationURL(
        for filename: String,
        in directory: URL,
        fileManager: FileManager
    ) -> URL {
        let candidateURL = directory.appendingPathComponent(filename)
        guard !fileManager.fileExists(atPath: candidateURL.path) else {
            let ext = candidateURL.pathExtension
            let baseName = candidateURL.deletingPathExtension().lastPathComponent
            var index = 2

            while true {
                let suffix = " \(index)"
                let adjustedName = ext.isEmpty ? "\(baseName)\(suffix)" : "\(baseName)\(suffix).\(ext)"
                let adjustedURL = directory.appendingPathComponent(adjustedName)
                if !fileManager.fileExists(atPath: adjustedURL.path) {
                    return adjustedURL
                }
                index += 1
            }
        }
        return candidateURL
    }

    // MARK: - Formatting helpers

    private var statusIconName: String {
        task.status == .completed ? "checkmark.circle.fill" : "xmark.circle.fill"
    }

    private var statusColor: Color {
        switch task.status {
        case .completed: return .green
        case .failed, .planFailed: return .red
        case .cancelled: return .gray
        case .timedOut, .maxIterations: return .orange
        default: return .gray
        }
    }

    private var formattedDuration: String {
        guard let start = task.startedAt else { return task.durationString }
        let end = task.completedAt ?? Date()
        let elapsed = Int(end.timeIntervalSince(start))
        let hours = elapsed / 3600
        let minutes = (elapsed % 3600) / 60
        let seconds = elapsed % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var totalTokens: Int {
        traceEvents.reduce(TraceTokenUsage.zero) { $0.adding($1.tokenUsage) }.effectiveTotal
    }

    private static let bulkFolderTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter
    }()
}

private enum BulkDeliverablesFolderError: LocalizedError {
    case noDeliverables
    case noReadableDeliverables

    var errorDescription: String? {
        switch self {
        case .noDeliverables:
            return "This task has no deliverables to export."
        case .noReadableDeliverables:
            return "None of the deliverables could be copied into the export folder."
        }
    }
}

// MARK: - Deliverable disclosure row

private struct DeliverableDisclosureRow: View {
    let path: String

    @State private var isExpanded = false
    @State private var showDocumentExporter = false

    private var url: URL { URL(fileURLWithPath: path) }
    private var filename: String { url.lastPathComponent }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: fileTypeIcon(for: url.pathExtension))
                        .font(.title3)
                        .foregroundStyle(.blue)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(filename)
                            .font(.subheadline)
                            .lineLimit(1)
                        Text(formattedFileSize)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if isExpanded {
                VStack(spacing: 8) {
                    QuickLookPreview(url: url)
                        .frame(height: 360)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    HStack(spacing: 16) {
                        Button {
                            showDocumentExporter = true
                        } label: {
                            Label("Save", systemImage: "square.and.arrow.down")
                                .font(.subheadline)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        ShareLink(item: url) {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .font(.subheadline)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .sheet(isPresented: $showDocumentExporter) {
            DocumentExporterView(sourceURL: url)
        }
    }

    private var formattedFileSize: String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64 else { return "" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    private func fileTypeIcon(for ext: String) -> String {
        switch ext.lowercased() {
        case "pdf": return "doc.richtext"
        case "png", "jpg", "jpeg", "gif", "webp", "heic": return "photo"
        case "mp4", "mov", "avi": return "film"
        case "zip", "tar", "gz": return "archivebox"
        case "txt", "md", "json", "csv": return "doc.text"
        case "swift", "py", "js", "ts", "html", "css": return "chevron.left.forwardslash.chevron.right"
        case "docx", "doc": return "doc.richtext"
        case "xlsx", "xls": return "tablecells"
        default: return "doc"
        }
    }
}

// MARK: - URL + Identifiable (for sheet binding)

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

// MARK: - Document exporter bridge

struct DocumentExporterView: UIViewControllerRepresentable {
    let sourceURLs: [URL]

    init(sourceURL: URL) {
        self.sourceURLs = [sourceURL]
    }

    init(sourceURLs: [URL]) {
        self.sourceURLs = sourceURLs
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: sourceURLs)
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
}

struct ActivityShareView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    NavigationStack {
        CompletedTaskDetailView(task: TaskRecord(
            id: "preview-completed",
            title: "Build the landing page",
            taskDescription: "Create a responsive landing page with hero section",
            status: .completed,
            startedAt: Date().addingTimeInterval(-300),
            completedAt: Date(),
            providerId: "cluster-remote:Anthropic",
            modelId: "claude-sonnet-4-20250514",
            resultSummary: "Successfully created a responsive landing page with hero section, features grid, and CTA."
        ))
        .environmentObject(ArtifactImportCoordinator())
        .environmentObject(HivelinkTaskService(
            modelContext: {
                let container = try! ModelContainer(for: TaskRecord.self)
                return ModelContext(container)
            }(),
            clusterCoordinator: HivelinkClusterCoordinator(),
            remoteTaskIndex: RemoteTaskIndex()
        ))
    }
}
