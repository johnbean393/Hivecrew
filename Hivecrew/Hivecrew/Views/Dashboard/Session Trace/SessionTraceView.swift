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
    @State var selectedTab: TraceTab = .trace
    @State var planState: PlanState? = nil
    @State var showingMissingAttachments: Bool = false
    @State var missingAttachmentsValidation: RerunAttachmentValidation? = nil
    
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
            events = parseTraceEvents(from: traceContent)
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
    
    // MARK: - Parse Trace
    
    func parseTraceEvents(from content: String) -> [TraceEventInfo] {
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        
        return lines.compactMap { line -> TraceEventInfo? in
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            
            let id = json["id"] as? String ?? UUID().uuidString
            let type = json["type"] as? String ?? "unknown"
            let timestamp = json["timestamp"] as? String ?? ""
            let step = json["step"] as? Int ?? 0
            
            // Extract summary, details, screenshot path, response text, and reasoning from data
            var summary = ""
            var details: String? = nil
            var screenshotPath: String? = nil
            var responseText: String? = nil
            var reasoning: String? = nil
            var subagentTracePath: String? = nil
            var subagentId: String? = nil
            var subagentStatus: String? = nil
            var subagentPurpose: String? = nil
            var subagentDomain: String? = nil
            if let eventData = json["data"] as? [String: Any] {
                let extracted = extractEventDetails(from: eventData, type: type)
                summary = extracted.summary
                details = extracted.details
                screenshotPath = extracted.screenshotPath
                responseText = extracted.responseText
                reasoning = extracted.reasoning
                subagentTracePath = extracted.subagentTracePath
                subagentId = extracted.subagentId
                subagentStatus = extracted.subagentStatus
                subagentPurpose = extracted.subagentPurpose
                subagentDomain = extracted.subagentDomain
            }
            
            return TraceEventInfo(
                id: id,
                type: type,
                timestamp: timestamp,
                step: step,
                summary: summary,
                rawJSON: line,
                screenshotPath: screenshotPath,
                details: details,
                responseText: responseText,
                reasoning: reasoning,
                subagentTracePath: subagentTracePath,
                subagentId: subagentId,
                subagentStatus: subagentStatus,
                subagentPurpose: subagentPurpose,
                subagentDomain: subagentDomain
            )
        }
    }
    
    private func extractEventDetails(from data: [String: Any], type: String) -> (
        summary: String,
        details: String?,
        screenshotPath: String?,
        responseText: String?,
        reasoning: String?,
        subagentTracePath: String?,
        subagentId: String?,
        subagentStatus: String?,
        subagentPurpose: String?,
        subagentDomain: String?
    ) {
        var summary = ""
        var details: String? = nil
        var screenshotPath: String? = nil
        var responseText: String? = nil
        var reasoning: String? = nil
        var subagentTracePath: String? = nil
        var subagentId: String? = nil
        var subagentStatus: String? = nil
        var subagentPurpose: String? = nil
        var subagentDomain: String? = nil
        
        switch type {
        case "session_start":
            if let sessionStart = data["sessionStart"] as? [String: Any],
               let inner = sessionStart["_0"] as? [String: Any] {
                summary = "Session started"
                details = inner["taskDescription"] as? String
            }
        case "session_end":
            if let sessionEnd = data["sessionEnd"] as? [String: Any],
               let inner = sessionEnd["_0"] as? [String: Any] {
                let status = inner["status"] as? String ?? "unknown"
                summary = "Session ended: \(status)"
                // The session summary often contains the final LLM response
                if let sessionSummary = inner["summary"] as? String {
                    details = sessionSummary
                    responseText = sessionSummary
                }
            }
        case "observation":
            if let observation = data["observation"] as? [String: Any],
               let inner = observation["_0"] as? [String: Any] {
                let width = inner["screenWidth"] as? Int ?? 0
                let height = inner["screenHeight"] as? Int ?? 0
                summary = "Screenshot captured"
                details = "\(width) x \(height)"
                screenshotPath = inner["screenshotPath"] as? String
            }
        case "llm_request":
            if let llmRequest = data["llmRequest"] as? [String: Any],
               let inner = llmRequest["_0"] as? [String: Any] {
                let model = inner["model"] as? String ?? "unknown"
                let messageCount = inner["messageCount"] as? Int ?? 0
                summary = "Sending request to LLM"
                details = "Model: \(model), \(messageCount) messages"
            }
        case "llm_response":
            if let llmResponse = data["llmResponse"] as? [String: Any],
               let inner = llmResponse["_0"] as? [String: Any] {
                let toolCallCount = inner["toolCallCount"] as? Int ?? 0
                let promptTokens = inner["promptTokens"] as? Int ?? 0
                let completionTokens = inner["completionTokens"] as? Int ?? 0
                // Prefer responseText (full text, new) over contentPreview (truncated, legacy)
                let fullResponseText = inner["responseText"] as? String
                let contentPreview = inner["contentPreview"] as? String
                // Extract reasoning tokens (optional for backward compatibility)
                reasoning = inner["reasoning"] as? String
                
                if toolCallCount > 0 {
                    summary = "LLM requested \(toolCallCount) tool call(s)"
                } else if let text = fullResponseText ?? contentPreview, !text.isEmpty {
                    summary = String(text.prefix(100)) + (text.count > 100 ? "..." : "")
                    // Use full text if available, otherwise fall back to preview
                    responseText = fullResponseText ?? contentPreview
                } else {
                    summary = "LLM responded"
                }
                details = "+\(promptTokens) prompt, +\(completionTokens) completion tokens"
            }
        case "tool_call":
            if let toolCall = data["toolCall"] as? [String: Any],
               let inner = toolCall["_0"] as? [String: Any] {
                let toolName = inner["toolName"] as? String ?? "unknown"
                summary = "Executing: \(toolName)"
                if let args = inner["arguments"] as? [String: Any] {
                    let argSummary = args.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
                    if !argSummary.isEmpty {
                        details = argSummary
                    }
                }
            }
        case "tool_result":
            if let toolResult = data["toolResult"] as? [String: Any],
               let inner = toolResult["_0"] as? [String: Any] {
                let success = inner["success"] as? Bool ?? false
                let toolName = inner["toolName"] as? String ?? "tool"
                let durationMs = inner["durationMs"] as? Int ?? 0
                summary = success ? "✓ \(toolName)" : "✗ \(toolName)"
                if let result = inner["result"] as? String, !result.isEmpty {
                    details = "\(result)\n(\(durationMs)ms)"
                } else {
                    details = "(\(durationMs)ms)"
                }
            }
        case "error":
            if let error = data["error"] as? [String: Any],
               let inner = error["_0"] as? [String: Any] {
                summary = "Error occurred"
                details = inner["message"] as? String
            }
        case "custom":
            if let custom = data["custom"] as? [String: Any] {
                let inner = (custom["_0"] as? [String: Any]) ?? custom
                if let eventType = inner["event_type"] as? String, eventType.hasPrefix("subagent_") {
                    subagentId = inner["subagent_id"] as? String
                    subagentTracePath = inner["trace_path"] as? String
                    subagentStatus = inner["status"] as? String
                    subagentPurpose = inner["purpose"] as? String
                    subagentDomain = inner["domain"] as? String
                    
                    let purposeText = subagentPurpose.map { " \($0)" } ?? ""
                    switch eventType {
                    case "subagent_started":
                        summary = "Subagent started:\(purposeText)"
                    case "subagent_completed":
                        summary = "Subagent completed:\(purposeText)"
                    case "subagent_failed":
                        summary = "Subagent failed:\(purposeText)"
                    case "subagent_cancelled":
                        summary = "Subagent cancelled:\(purposeText)"
                    default:
                        summary = "Subagent event:\(purposeText)"
                    }
                    
                    var detailParts: [String] = []
                    if let domain = subagentDomain { detailParts.append("Domain: \(domain)") }
                    if let status = subagentStatus { detailParts.append("Status: \(status)") }
                    if let allowlist = inner["tool_allowlist"] as? String { detailParts.append("Tools: \(allowlist)") }
                    if let duration = inner["duration_ms"] as? String { detailParts.append("Duration: \(duration)ms") }
                    if let errorMessage = inner["error"] as? String { detailParts.append("Error: \(errorMessage)") }
                    details = detailParts.isEmpty ? nil : detailParts.joined(separator: " • ")
                } else {
                    summary = "Custom event"
                }
            }
        default:
            summary = type.replacingOccurrences(of: "_", with: " ").capitalized
        }
        
        return (
            summary,
            details,
            screenshotPath,
            responseText,
            reasoning,
            subagentTracePath,
            subagentId,
            subagentStatus,
            subagentPurpose,
            subagentDomain
        )
    }
}

// MARK: - Preview

#Preview {
    SessionTraceView(task: TaskRecord(
        title: "Open Firefox and go to google.com",
        taskDescription: "Navigate to Google homepage using Firefox browser",
        status: .completed,
        providerId: "openai",
        modelId: "gpt-5.2"
    ))
}
