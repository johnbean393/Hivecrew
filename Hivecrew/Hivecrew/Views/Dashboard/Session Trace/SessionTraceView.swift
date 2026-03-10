//
//  SessionTraceView.swift
//  Hivecrew
//
//  View for displaying session trace logs with synchronized screenshot viewer
//

import SwiftUI
import SwiftData
import TipKit
import QuickLook
import AppKit
import HivecrewShared
import MarkdownView

/// View for displaying session trace logs with screenshot playback synced to scroll
struct SessionTraceView: View {
    
    let task: TaskRecord
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var taskService: TaskService
    
    @State private var traceContent: String = ""
    @State private var isLoading: Bool = true
    @State private var errorMessage: String?
    @State var events: [TraceEventInfo] = []
    @State var screenshotEvents: [TraceEventInfo] = []
    @State var quickLookURL: URL? = nil
    @State private var visibleEventIds: Set<String> = []
    @State var currentScreenshotPath: String? = nil
    @State var currentScreenshotStep: Int = 0
    @State var isExportingVideo: Bool = false
    @State var exportProgress: Double = 0
    @State var showingSkillExtraction: Bool = false
    @State var sessionTokenUsageSummary: TraceTokenUsage? = nil
    @State var selectedTab: TraceTab = .trace
    @State var planState: PlanState? = nil
    @State var showingRerunModelSelection: Bool = false
    @State var showingMissingAttachments: Bool = false
    @State var missingAttachmentsValidation: RerunAttachmentValidation? = nil
    @State var rerunTargetOverride: (providerId: String, modelId: String, reasoningEnabled: Bool?, reasoningEffort: String?)? = nil
    
    enum TraceTab: String, CaseIterable {
        case trace = "Trace"
        case plan = "Plan"
        
        var localizedName: String {
            switch self {
            case .trace: return String(localized: "Trace")
            case .plan: return String(localized: "Plan")
            }
        }
    }
    
    /// Whether the task has a plan
    var hasPlan: Bool {
        task.planFirstEnabled && (task.planMarkdown != nil || planState != nil)
    }
    
    var sessionDirectory: URL? {
        guard let sessionId = task.sessionId else { return nil }
        return AppPaths.sessionDirectory(id: sessionId)
    }
    
    // Tips (accessed from extension)
    let extractSkillTip = ExtractSkillTip()
    let videoExportTip = VideoExportTip()
    
    /// The last LLM text response (from session_end summary or llm_response with no tool calls)
    var lastLLMTextResponse: String? {
        // Find the last event that has a responseText
        // Priority: session_end summary (most complete), then llm_response with no tool calls
        for event in events.reversed() {
            if let text = event.responseText, !text.isEmpty {
                // session_end summary or llm_response text
                if event.type == "session_end" || event.type == "llm_response" {
                    return text
                }
            }
        }
        return nil
    }

    var body: some View {
        Group {
            if isLoading {
                loadingView
            } else if let error = errorMessage {
                errorView(error)
            } else if events.isEmpty {
                emptyView
            } else {
                mainContentView
            }
        }
        .frame(minWidth: 1000, minHeight: 600, maxHeight: 750)
        .onAppear {
            loadTrace()
            // Track session trace view for tips
            TipStore.shared.donateSessionTraceViewed()
            // Update tip state if task was successful
            if task.wasSuccessful == true {
                TipStore.shared.successfulTaskCompleted()
            }
        }
        .quickLookPreview($quickLookURL)
        .sheet(isPresented: $showingSkillExtraction) {
            SkillExtractionSheet(task: task, taskService: taskService)
        }
    }
    
    // MARK: - Main Content View
    
    private var mainContentView: some View {
        HStack(spacing: 0) {
            // Left side - Screenshot viewer (synced to scroll)
            screenshotViewer
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
            
            Divider()
            
            // Right side - Trace panel
            tracePanel
                .frame(width: 400)
        }
    }
    
    // MARK: - Status Color
    
    var statusColor: Color {
        switch task.status {
        case .completed:
            // Use wasSuccessful to determine color
            if let success = task.wasSuccessful {
                return success ? .green : .red
            }
            return .green
        case .failed: return .red
        case .cancelled: return .orange
        case .running: return .blue
        case .paused: return .yellow
        case .timedOut, .maxIterations: return .orange
        default: return .gray
        }
    }
    
    /// Icon for completion status
    var completionIcon: String? {
        guard task.status == .completed else { return nil }
        if let success = task.wasSuccessful {
            return success ? "checkmark.circle.fill" : "xmark.circle.fill"
        }
        return nil
    }
    
    /// Display text for verified status
    var statusDisplayText: String {
        if task.status == .completed, let success = task.wasSuccessful {
            return success ? String(localized: "Verified Complete") : String(localized: "Incomplete")
        }
        return task.status.displayName
    }
    
    func formatTimestamp(_ timestamp: String) -> String {
        let formatter = ISO8601DateFormatter()
        
        // Try with fractional seconds first
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: timestamp) {
            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "HH:mm:ss"
            return timeFormatter.string(from: date)
        }
        
        // Try without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: timestamp) {
            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "HH:mm:ss"
            return timeFormatter.string(from: date)
        }
        
        return timestamp
    }

    func formatTokenCount(_ value: Int) -> String {
        switch value {
        case 1_000_000...:
            let abbreviated = Double(value) / 1_000_000
            let formatted = abbreviated.rounded() == abbreviated
                ? String(Int(abbreviated))
                : String(format: "%.1f", abbreviated)
            return "\(formatted)M"
        case 1_000...:
            let abbreviated = Double(value) / 1_000
            let formatted = abbreviated.rounded() == abbreviated
                ? String(Int(abbreviated))
                : String(format: "%.1f", abbreviated)
            return "\(formatted)k"
        default:
            return "\(value)"
        }
    }
    
    // MARK: - Loading View
    
    private var loadingView: some View {
        VStack {
            Spacer()
            ProgressView()
            Text("Loading trace...")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Error View
    
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("Failed to load trace")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Empty View
    
    private var emptyView: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "doc.text")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("No trace data available")
                .font(.headline)
            Text("The session may not have generated any trace events")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Load Trace
    
    private func loadTrace() {
        guard let sessionId = task.sessionId else {
            isLoading = false
            errorMessage = "No session ID"
            return
        }
        
        let sessionDir = AppPaths.sessionDirectory(id: sessionId)
        let traceFile = sessionDir.appendingPathComponent("trace.jsonl")
        
        do {
            traceContent = try String(contentsOf: traceFile, encoding: .utf8)
            events = SessionTraceParser.parseEvents(from: traceContent)
            sessionTokenUsageSummary = calculateSessionTokenUsage(
                from: events,
                sessionDirectory: sessionDir
            )
            screenshotEvents = events.filter { $0.screenshotPath != nil }
            
            // Initialize with first screenshot
            if let firstScreenshot = screenshotEvents.first {
                currentScreenshotPath = firstScreenshot.screenshotPath
                currentScreenshotStep = firstScreenshot.step
            }
            
            // Load plan state if available
            loadPlanState(sessionId: sessionId)
            
            isLoading = false
        } catch {
            isLoading = false
            sessionTokenUsageSummary = nil
            errorMessage = error.localizedDescription
        }
    }
    
    private func loadPlanState(sessionId: String) {
        let planStatePath = AppPaths.sessionPlanStatePath(id: sessionId)
        
        guard FileManager.default.fileExists(atPath: planStatePath.path) else {
            return
        }
        
        do {
            let data = try Data(contentsOf: planStatePath)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            planState = try decoder.decode(PlanState.self, from: data)
        } catch {
            print("Failed to load plan state: \(error)")
        }
    }

    func parseTraceEvents(from content: String) -> [TraceEventInfo] {
        SessionTraceParser.parseEvents(from: content)
    }

    private func calculateSessionTokenUsage(
        from events: [TraceEventInfo],
        sessionDirectory: URL
    ) -> TraceTokenUsage? {
        var visitedTracePaths: Set<String> = []
        let usage = aggregateTokenUsage(
            from: events,
            sessionDirectory: sessionDirectory,
            visitedTracePaths: &visitedTracePaths
        )
        return usage.hasUsage ? usage : nil
    }

    private func aggregateTokenUsage(
        from events: [TraceEventInfo],
        sessionDirectory: URL,
        visitedTracePaths: inout Set<String>
    ) -> TraceTokenUsage {
        var usage = events.reduce(into: TraceTokenUsage.zero) { partial, event in
            partial = partial.adding(
                TraceTokenUsage(
                    prompt: event.tokenUsage.prompt,
                    completion: event.tokenUsage.completion,
                    total: event.tokenUsage.effectiveTotal
                )
            )
        }

        let subagentTracePaths: Set<String> = Set(
            events.compactMap { event in
                guard let path = event.subagentTracePath?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !path.isEmpty else {
                    return nil
                }
                return path
            }
        )

        for relativePath in subagentTracePaths {
            let traceURL = sessionDirectory.appendingPathComponent(relativePath).standardizedFileURL
            guard visitedTracePaths.insert(traceURL.path).inserted else { continue }

            do {
                let content = try String(contentsOf: traceURL, encoding: .utf8)
                let nestedEvents = parseTraceEvents(from: content)
                usage = usage.adding(
                    aggregateTokenUsage(
                        from: nestedEvents,
                        sessionDirectory: sessionDirectory,
                        visitedTracePaths: &visitedTracePaths
                    )
                )
            } catch {
                print("Failed to load subagent trace for token usage: \(error)")
            }
        }

        return usage
    }
}

// MARK: - Preview

#Preview {
    SessionTraceView(task: TaskRecord(
        title: "Open Firefox and go to google.com",
        taskDescription: "Navigate to Google homepage using Firefox browser",
        status: .completed,
        providerId: "openai",
        modelId: "moonshotai/kimi-k2.5"
    ))
}
