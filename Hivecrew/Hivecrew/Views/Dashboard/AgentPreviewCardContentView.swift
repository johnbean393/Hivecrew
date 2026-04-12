//
//  AgentPreviewCardContentView.swift
//  Hivecrew
//
//  Shared content for agent preview cards
//

import SwiftUI
import AppKit
import HivecrewAPI

struct AgentPreviewCardContent: View {
    let task: TaskRecord
    let statePublisher: AgentStatePublisher?
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let previewHeight: CGFloat
    let previewScreenshot: NSImage?
    let previewScreenshotPath: String?
    
    @EnvironmentObject var taskService: TaskService
    @ObservedObject private var clusterStatus = ClusterStatus.shared
    @State private var showingTrace: Bool = false
    @State private var showingPlanReview: Bool = false
    @State private var showingWritebackReview: Bool = false
    @State private var remoteScreenshot: NSImage?
    @State private var remoteActivitySummary: String?
    @State private var remoteStepCount: Int = 0
    @State private var remoteEventSince: Int = 0
    @State private var remotePollTask: Task<Void, Never>?
    
    private var hasPendingQuestion: Bool {
        statePublisher?.pendingQuestion != nil
    }
    
    private var hasPendingPermission: Bool {
        statePublisher?.pendingPermissionRequest != nil
    }
    
    private var needsIntervention: Bool {
        hasPendingQuestion || hasPendingPermission || task.status == .planReview || task.status == .writebackReview
    }
    
    private var stepCount: Int {
        statePublisher?.currentStep ?? remoteStepCount
    }
    
    private var activityDescription: String {
        if let question = statePublisher?.pendingQuestion {
            let prefix = question.isIntervention ? "Intervention needed" : "Question"
            return "\(prefix): \(question.question)"
        }
        if let permission = statePublisher?.pendingPermissionRequest {
            return "Permission required: \(permission.toolName)"
        }
        if let ownerLabel {
            return ownerLabel
        }
        if task.status == .planReview {
            return "Plan ready for review"
        }
        if let currentTool = statePublisher?.currentToolCall, !currentTool.isEmpty {
            return "Running: \(currentTool)"
        }
        if let lastEntry = statePublisher?.activityLog.last?.summary, !lastEntry.isEmpty {
            return lastEntry
        }
        if let remoteActivitySummary, !remoteActivitySummary.isEmpty {
            return remoteActivitySummary
        }
        return statusDescription
    }

    private var ownerLabel: String? {
        guard task.isInternalClusterExecution else { return nil }
        let ownerName = clusterStatus.displayName(forPeerId: task.clusterOwnerNodeId)
            ?? task.clusterOwnerNodeId.map(shortOwnerLabel(for:))
        guard let ownerName, !ownerName.isEmpty else { return "Leased Task" }
        return "From \(ownerName)"
    }
    
    private var statusDescription: String {
        if let nodeName = task.remoteNodeDisplayName {
            switch task.remoteLeaseState {
            case .suspect:
                return "Checking \(nodeName)"
            case .recovering:
                return "Recovering from \(nodeName)"
            case .completedAwaitingImport:
                return "Importing from \(nodeName)"
            default:
                break
            }
            switch task.clusterExecutionState {
            case .dispatchingRemote:
                return "Starting on \(nodeName)"
            case .recoveringRemote:
                return "Reconnecting to \(nodeName)"
            case .runningRemote:
                return "Running on \(nodeName)"
            default:
                break
            }
        }
        switch effectiveStatus {
        case .queued:
            return "Queued"
        case .waitingForVM:
            return "Awaiting VM"
        case .planning:
            return "Generating plan"
        case .planReview:
            return "Awaiting plan review"
        case .writebackReview:
            return "Changes ready to apply"
        case .running:
            return "In progress"
        case .paused:
            return "Paused"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        case .timedOut:
            return "Timed out"
        case .maxIterations:
            return "Max iterations"
        case .planFailed:
            return "Planning failed"
        }
    }
    
    private var planStateForDisplay: PlanState? {
        if let planProgress = statePublisher?.planProgress, !planProgress.items.isEmpty {
            return planProgress
        }
        if let planMarkdown = task.planMarkdown {
            let items = PlanParser.parseTodos(from: planMarkdown)
            if !items.isEmpty {
                return PlanState(items: items)
            }
        }
        return nil
    }
    
    var body: some View {
        Button(action: handleCardTap) {
            VStack(
                alignment: .leading,
                spacing: 8
            ) {
                headerRow
                VStack {
                    Spacer(minLength: 0)
                    previewImage
                    Spacer(minLength: 0)
                }
                HStack(alignment: .center, spacing: 12) {
                    VStack(
                        alignment: .leading,
                        spacing: 8
                    ) {
                        Text("Steps \(stepCount)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(activityDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .layoutPriority(1)
                    if let planState = planStateForDisplay {
                        planProgressRow(planState)
                            .frame(width: 120)
                    }
                    Spacer(minLength: 0)
                    controlRow
                }
            }
            .padding(10)
            .frame(width: cardWidth, height: cardHeight, alignment: .top)
            .clipped()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingTrace) {
            SessionTraceView(task: task)
        }
        .sheet(isPresented: $showingPlanReview) {
            PlanReviewWindow(task: task, taskService: taskService)
        }
        .sheet(isPresented: $showingWritebackReview) {
            WritebackReviewWindow(task: task, taskService: taskService)
        }
        .onAppear {
            startRemotePollingIfNeeded()
        }
        .onChange(of: task.clusterExecutionState) { _, _ in
            startRemotePollingIfNeeded()
        }
        .onDisappear {
            remotePollTask?.cancel()
            remotePollTask = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            startRemotePollingIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            startRemotePollingIfNeeded()
        }
    }
    
    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(task.title)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .lineLimit(1)
            
            Spacer()
            
            if let nodeName = task.remoteNodeDisplayName {
                StatusPill(text: nodeName, color: .blue)
            }

            if let ownerLabel {
                StatusPill(text: ownerLabel, color: .blue)
            }
            
            if needsIntervention {
                StatusPill(text: interventionPillText, color: .orange)
            } else if task.isExecutingRemotely {
                StatusPill(
                    text: "Remote",
                    color: .blue
                )
            } else {
                StatusPill(text: effectiveStatus.displayName, color: statusPillColor)
            }
        }
    }
    
    private var interventionPillText: String {
        if task.status == .planReview && !hasPendingQuestion && !hasPendingPermission {
            return "Needs review"
        }
        if task.status == .writebackReview && !hasPendingQuestion && !hasPendingPermission {
            return "Review changes"
        }
        return "Needs input"
    }
    
    private var statusPillColor: Color {
        switch effectiveStatus {
        case .running: return .green
        case .paused, .queued, .waitingForVM, .planning: return .yellow
        case .planReview, .writebackReview: return .blue
        case .failed, .planFailed: return .red
        case .cancelled: return .gray
        case .timedOut, .maxIterations: return .orange
        case .completed: return .secondary
        }
    }

    private var effectiveStatus: TaskStatus {
        taskService.effectiveStatus(for: task)
    }
    
    private var previewImage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.6))
            
            if let screenshot = previewScreenshot ?? remoteScreenshot {
                Image(nsImage: screenshot)
                    .resizable()
                    .scaledToFill()
            } else if task.isExecutingRemotely {
                VStack(spacing: 6) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 22))
                        .foregroundStyle(.blue)
                    if let nodeName = task.remoteNodeDisplayName {
                        Text(nodeName)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.blue)
                    }
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                    Text("No preview yet")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16/9, contentMode: .fit)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    
    private func planProgressRow(_ planState: PlanState) -> some View {
        HStack(spacing: 8) {
            ProgressView(value: planState.completionPercentage)
                .frame(maxWidth: .infinity)
            Text("\(planState.completedCount)/\(planState.items.count)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
    
    private var controlRow: some View {
        HStack(spacing: 8) {
            if effectiveStatus == .running {
                Button {
                    taskService.pauseTask(task)
                } label: {
                    Image(systemName: "pause.circle.fill")
                        .imageScale(.large)
                }
                .buttonStyle(.borderless)
                .tint(.yellow)
                .controlSize(.small)
                .help("Pause agent")
            } else if effectiveStatus == .paused {
                Button {
                    taskService.resumeTask(task)
                } label: {
                    Image(systemName: "play.circle.fill")
                        .imageScale(.large)
                }
                .buttonStyle(.borderless)
                .tint(.green)
                .controlSize(.small)
                .help("Resume agent")
            } else if effectiveStatus == .planReview {
                Button {
                    Task { await taskService.executePlan(for: task) }
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .imageScale(.large)
                }
                .buttonStyle(.borderless)
                .tint(.green)
                .controlSize(.small)
                .help("Approve and execute plan")
            } else if effectiveStatus == .writebackReview {
                Button {
                    showingWritebackReview = true
                } label: {
                    Image(systemName: "square.and.arrow.down.on.square.fill")
                        .imageScale(.large)
                }
                .buttonStyle(.borderless)
                .tint(.blue)
                .controlSize(.small)
                .help("Review staged local changes")
            }
            
            if effectiveStatus != .writebackReview {
                Button {
                    stopTask()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .imageScale(.large)
                }
                .buttonStyle(.borderless)
                .tint(.red)
                .controlSize(.small)
                .help(stopHelpText)
            }
        }
    }

    private func handleCardTap() {
        if effectiveStatus == .planning || effectiveStatus == .planReview {
            showingPlanReview = true
        } else if effectiveStatus == .writebackReview {
            showingWritebackReview = true
        } else if effectiveStatus == .queued || effectiveStatus == .waitingForVM {
            return
        } else if effectiveStatus == .running || effectiveStatus == .paused {
            navigateToTask(task.id)
        } else {
            showingTrace = true
        }
    }

    private func navigateToTask(_ taskId: String) {
        NotificationCenter.default.post(
            name: .navigateToTask,
            object: nil,
            userInfo: ["taskId": taskId]
        )
    }
    
    private var stopHelpText: String {
        switch effectiveStatus {
        case .queued, .waitingForVM:
            return "Remove from queue"
        case .planning, .planReview:
            return "Cancel planning"
        case .writebackReview:
            return "Review staged changes"
        default:
            return "Stop agent"
        }
    }
    
    private func stopTask() {
        switch effectiveStatus {
        case .queued, .waitingForVM:
            Task { await taskService.removeFromQueue(task) }
        case .planning, .planReview:
            Task { await taskService.cancelPlanning(for: task) }
        case .writebackReview:
            break
        case .running, .paused:
            Task { await taskService.cancelTask(task) }
        default:
            break
        }
    }

    @MainActor
    private func startRemotePollingIfNeeded() {
        guard task.isExecutingRemotely, statePublisher == nil else { return }
        remotePollTask?.cancel()
        remotePollTask = Task {
            while !Task.isCancelled {
                await pollRemoteSnapshot()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    @MainActor
    private func pollRemoteSnapshot() async {
        guard let provider = APIServerManager.shared.federatedProvider else { return }

        if let remoteTask = try? await provider.getTask(id: task.id) {
            if let stepCount = remoteTask.stepCount {
                remoteStepCount = stepCount
            }
        }

        if let screenshot = try? await provider.getTaskScreenshot(id: task.id),
           let image = NSImage(data: screenshot.data) {
            remoteScreenshot = image
        }

        if let response = try? await provider.getTaskActivity(id: task.id, since: remoteEventSince) {
            if !response.events.isEmpty {
                remoteActivitySummary = response.events.last.flatMap { eventSummary(for: $0) } ?? remoteActivitySummary
            }
            remoteEventSince = response.total
        }
    }

    private func eventSummary(for event: APITaskEvent) -> String? {
        if case .string(let summary)? = event.data["summary"] {
            return summary
        }
        return nil
    }

    private func shortOwnerLabel(for ownerNodeId: String) -> String {
        if ownerNodeId.count <= 8 {
            return ownerNodeId
        }
        return String(ownerNodeId.prefix(8))
    }
}
