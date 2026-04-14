//
//  CallTaskDetailView.swift
//  Hivecrew
//
//  Detail view for a focused task in the call task pane.
//  Adapts content based on task status:
//    - Queued / waiting: prompt, attachments, status badge
//    - Running: live screenshot + live agent trace (reuses TraceEntryView, StreamingReasoningView)
//    - Completed: prompt, attachments, deliverables, scroll-synced screenshot + historical trace
//      (reuses HistoricalTraceEventRow, SubagentTraceEventRow, SessionTraceParser,
//       VisibleEventPreferenceKey, EventVisibility)
//

import SwiftUI
import QuickLook
import AppKit
import HivecrewCore
import HivecrewShared

struct CallTaskDetailView: View {

    let task: TaskRecord
    @EnvironmentObject var orchestrator: VoiceOrchestrator
    @EnvironmentObject var taskService: TaskService

    // MARK: - State for completed-task trace

    @State private var traceEvents: [TraceEventInfo] = []
    @State private var screenshotEvents: [TraceEventInfo] = []
    @State private var currentScreenshotPath: String?
    @State private var isTraceLoaded = false
    @State private var quickLookURL: URL?
    @State private var selectedDeliverableIndex: Int = 0

    // MARK: - Derived

    private var worker: WorkerIdentity? {
        orchestrator.workerRegistry.workers.first { $0.id == task.id }
    }

    private var statePublisher: AgentStatePublisher? {
        taskService.statePublishers[task.id]
    }

    private var sessionDirectory: URL? {
        guard let sessionId = task.sessionId else { return nil }
        return AppPaths.sessionDirectory(id: sessionId)
    }

    private var deliverablePaths: [String] {
        (task.outputFilePaths ?? []).filter { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: - Body

    var body: some View {
        Group {
            switch task.status {
            case .queued, .waitingForVM, .planning, .planReview, .planFailed:
                queuedContent
            case .running, .paused:
                if let publisher = statePublisher {
                    LiveTaskContentView(publisher: publisher, sessionDirectory: sessionDirectory, quickLookURL: $quickLookURL)
                } else {
                    VStack { Spacer(); ProgressView("Connecting…"); Spacer() }
                }
            default:
                completedContent
            }
        }
        .quickLookPreview($quickLookURL)
    }

    // MARK: - Queued / Waiting

    private var queuedContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                workerHeader
                Divider()
                promptSection
                attachmentsSection
            }
            .padding()
        }
    }

    // MARK: - Completed / Failed / Cancelled

    private var completedContent: some View {
        VStack(spacing: 0) {
            if isTraceLoaded, !traceEvents.isEmpty {
                if deliverablePaths.isEmpty {
                    completedNoDeliverablesLayout
                } else {
                    completedWithDeliverablesLayout
                }
            } else if isTraceLoaded {
                taskSummaryHeader
                Divider()
                if !deliverablePaths.isEmpty {
                    deliverablesViewer
                } else {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text")
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)
                        Text("No trace data")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            } else {
                Spacer()
                ProgressView("Loading trace…")
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { loadTrace() }
    }

    /// Screenshot on top, trace below (existing layout).
    private var completedNoDeliverablesLayout: some View {
        VStack(spacing: 0) {
            screenshotViewer
                .frame(maxWidth: .infinity)
                .frame(minHeight: 140, idealHeight: 200)
                .background(Color.black)

            Divider()

            historicalTraceView
        }
    }

    /// Screenshot + trace side-by-side on top, QuickLook deliverables on bottom.
    private var completedWithDeliverablesLayout: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    screenshotViewer
                        .frame(minWidth: 160)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)

                    Divider()

                    traceScrollContent
                        .frame(minWidth: 180)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(height: geo.size.height * 0.5)

                Divider()

                deliverablesViewer
                    .frame(maxHeight: .infinity)
            }
        }
    }

    // MARK: - Trace Scroll (without summary header)

    private var traceScrollContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(Array(traceEvents.enumerated()), id: \.element.id) { index, event in
                    Group {
                        if let sessionDir = sessionDirectory, event.subagentTracePath != nil {
                            SubagentTraceEventRow(
                                event: event,
                                sessionDirectory: sessionDir,
                                parseTraceEvents: { SessionTraceParser.parseEvents(from: $0, sessionDirectory: sessionDir) }
                            )
                        } else {
                            HistoricalTraceEventRow(
                                event: event,
                                isCurrentScreenshot: event.screenshotPath == currentScreenshotPath
                            )
                        }
                    }
                    .id(event.id)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: VisibleEventPreferenceKey.self,
                                value: [EventVisibility(
                                    id: event.id,
                                    index: index,
                                    minY: geo.frame(in: .named("callTraceScrollCompact")).minY,
                                    maxY: geo.frame(in: .named("callTraceScrollCompact")).maxY
                                )]
                            )
                        }
                    )
                }
                Spacer(minLength: 60)
            }
            .padding(8)
        }
        .coordinateSpace(name: "callTraceScrollCompact")
        .onPreferenceChange(VisibleEventPreferenceKey.self) { visibilities in
            updateScreenshotForVisibleEvents(visibilities)
        }
    }

    // MARK: - Deliverables Viewer (QuickLook + tab strip)

    private var deliverablesViewer: some View {
        VStack(spacing: 0) {
            let paths = deliverablePaths
            let safeIndex = min(selectedDeliverableIndex, max(0, paths.count - 1))

            if !paths.isEmpty {
                InlineQuickLookPreview(url: URL(fileURLWithPath: paths[safeIndex]))
                    .id(paths[safeIndex])
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            deliverableTabStrip
        }
    }

    private var deliverableTabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(deliverablePaths.enumerated()), id: \.element) { index, path in
                    let url = URL(fileURLWithPath: path)
                    let isSelected = index == min(selectedDeliverableIndex, max(0, deliverablePaths.count - 1))

                    Button {
                        selectedDeliverableIndex = index
                    } label: {
                        HStack(spacing: 5) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                                .resizable()
                                .frame(width: 16, height: 16)
                            Text(url.lastPathComponent)
                                .font(.caption)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Screenshot Viewer (completed – same pattern as SessionTraceView+Panels)

    @ViewBuilder
    private var screenshotViewer: some View {
        if screenshotEvents.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text("No screenshots")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            ZStack {
                Color.black
                if let path = currentScreenshotPath,
                   let image = NSImage(contentsOfFile: path) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .onTapGesture { quickLookURL = URL(fileURLWithPath: path) }
                        .transition(.opacity)
                } else if let first = screenshotEvents.first?.screenshotPath,
                          let image = NSImage(contentsOfFile: first) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .onTapGesture { quickLookURL = URL(fileURLWithPath: first) }
                }
            }
            .animation(.easeInOut(duration: 0.15), value: currentScreenshotPath)
        }
    }

    // MARK: - Historical Trace (completed – reuses rows + scroll-sync from SessionTraceModels)

    private var historicalTraceView: some View {
        VStack(alignment: .leading, spacing: 0) {
            taskSummaryHeader
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(traceEvents.enumerated()), id: \.element.id) { index, event in
                        Group {
                            if let sessionDir = sessionDirectory, event.subagentTracePath != nil {
                                SubagentTraceEventRow(
                                    event: event,
                                    sessionDirectory: sessionDir,
                                    parseTraceEvents: { SessionTraceParser.parseEvents(from: $0, sessionDirectory: sessionDir) }
                                )
                            } else {
                                HistoricalTraceEventRow(
                                    event: event,
                                    isCurrentScreenshot: event.screenshotPath == currentScreenshotPath
                                )
                            }
                        }
                        .id(event.id)
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: VisibleEventPreferenceKey.self,
                                    value: [EventVisibility(
                                        id: event.id,
                                        index: index,
                                        minY: geo.frame(in: .named("callTraceScroll")).minY,
                                        maxY: geo.frame(in: .named("callTraceScroll")).maxY
                                    )]
                                )
                            }
                        )
                    }
                    Spacer(minLength: 200)
                }
                .padding()
            }
            .coordinateSpace(name: "callTraceScroll")
            .onPreferenceChange(VisibleEventPreferenceKey.self) { visibilities in
                updateScreenshotForVisibleEvents(visibilities)
            }
        }
    }

    // MARK: - Scroll-sync (same logic as SessionTraceView)

    private func updateScreenshotForVisibleEvents(_ visibilities: [EventVisibility]) {
        let visibleThreshold: CGFloat = 120
        let visible = visibilities
            .filter { $0.minY < visibleThreshold && $0.maxY > 0 }
            .sorted { $0.index < $1.index }

        guard let topmost = visible.first else { return }

        for i in stride(from: topmost.index, through: 0, by: -1) {
            if let path = traceEvents[safe: i]?.screenshotPath {
                if currentScreenshotPath != path {
                    withAnimation(.easeInOut(duration: 0.15)) { currentScreenshotPath = path }
                }
                return
            }
        }

        if let first = screenshotEvents.first, currentScreenshotPath != first.screenshotPath {
            withAnimation(.easeInOut(duration: 0.15)) { currentScreenshotPath = first.screenshotPath }
        }
    }

    // MARK: - Load Trace

    private func loadTrace() {
        guard !isTraceLoaded, let sessionId = task.sessionId else {
            isTraceLoaded = true
            return
        }
        let traceFile = AppPaths.sessionDirectory(id: sessionId).appendingPathComponent("trace.jsonl")
        do {
            let content = try String(contentsOf: traceFile, encoding: .utf8)
            traceEvents = SessionTraceParser.parseEvents(from: content, sessionDirectory: AppPaths.sessionDirectory(id: sessionId))
            screenshotEvents = traceEvents.filter { $0.screenshotPath != nil }
            if let first = screenshotEvents.first {
                currentScreenshotPath = first.screenshotPath
            }
        } catch {
            // Trace file not available — handled by empty-state branch
        }
        isTraceLoaded = true
    }

    // MARK: - Shared Sub-views

    private var workerHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                if let worker {
                    Text(worker.displayName)
                        .font(.title3.bold())
                    Text(worker.taskTitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                statusBadge
            }
            Spacer()
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(task.status.displayName)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Prompt")
                .font(.caption.bold())
                .foregroundColor(.secondary)
            Text(task.taskDescription)
                .font(.body)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var attachmentsSection: some View {
        let infos = task.attachmentInfos
        if !infos.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Attachments")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                ForEach(infos, id: \.effectivePath) { info in
                    HStack(spacing: 6) {
                        Image(systemName: "paperclip")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(URL(fileURLWithPath: info.effectivePath).lastPathComponent)
                            .font(.caption)
                            .foregroundColor(.blue)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var deliverablesSection: some View {
        if let files = task.outputFilePaths, !files.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Deliverables")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                ForEach(files, id: \.self) { path in
                    HStack(spacing: 6) {
                        Image(systemName: "doc")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                            .font(.caption)
                            .foregroundColor(.blue)
                            .lineLimit(1)
                            .onTapGesture {
                                quickLookURL = URL(fileURLWithPath: path)
                            }
                    }
                }
            }
        }
    }

    private var taskSummaryHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            workerHeader
            promptSection
            attachmentsSection
            deliverablesSection
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var statusColor: Color {
        switch task.status {
        case .running: return .green
        case .completed: return .blue
        case .failed, .cancelled: return .red
        case .queued, .paused, .waitingForVM, .planning: return .orange
        default: return .secondary
        }
    }
}

// MARK: - Live Task Content (Running)
// Extracted so the AgentStatePublisher can be properly observed via @ObservedObject.

private struct LiveTaskContentView: View {

    @ObservedObject var publisher: AgentStatePublisher
    let sessionDirectory: URL?
    @Binding var quickLookURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            screenshotViewer
                .frame(maxWidth: .infinity)
                .frame(minHeight: 160, idealHeight: 220)
                .background(Color.black)

            Divider()

            traceView
        }
    }

    @ViewBuilder
    private var screenshotViewer: some View {
        if let image = publisher.lastScreenshot {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .onTapGesture {
                    if let path = publisher.lastScreenshotPath {
                        quickLookURL = URL(fileURLWithPath: path)
                    }
                }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "display")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text("Waiting for screenshot…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var traceView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(publisher.activityLog) { entry in
                        TraceEntryView(entry: entry, statePublisher: publisher)
                            .id(entry.id)
                    }

                    if publisher.isReasoningStreaming && !publisher.streamingReasoning.isEmpty {
                        StreamingReasoningView(reasoning: publisher.streamingReasoning)
                            .id("streaming-reasoning")
                    }
                }
                .padding()
            }
            .scrollIndicators(.never)
            .onChange(of: publisher.activityLog.count) { oldCount, newCount in
                guard newCount > oldCount, let last = publisher.activityLog.last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onChange(of: publisher.streamingReasoning) { _, _ in
                guard publisher.isReasoningStreaming else { return }
                withAnimation { proxy.scrollTo("streaming-reasoning", anchor: .bottom) }
            }
        }
    }
}
