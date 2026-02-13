//
//  AgentPreviewCardContentView.swift
//  Hivecrew
//
//  Shared content for agent preview cards
//

import SwiftUI

struct AgentPreviewCardContent: View {
    let task: TaskRecord
    let statePublisher: AgentStatePublisher?
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let previewHeight: CGFloat
    let previewScreenshot: NSImage?
    let previewScreenshotPath: String?
    
    @EnvironmentObject var taskService: TaskService
    @State private var showingTrace: Bool = false
    @State private var showingPlanReview: Bool = false
    
    private var hasPendingQuestion: Bool {
        statePublisher?.pendingQuestion != nil
    }
    
    private var hasPendingPermission: Bool {
        statePublisher?.pendingPermissionRequest != nil
    }
    
    private var needsIntervention: Bool {
        hasPendingQuestion || hasPendingPermission || task.status == .planReview
    }
    
    private var stepCount: Int {
        statePublisher?.currentStep ?? 0
    }
    
    private var activityDescription: String {
        if let question = statePublisher?.pendingQuestion {
            let prefix = question.isIntervention ? "Intervention needed" : "Question"
            return "\(prefix): \(question.question)"
        }
        if let permission = statePublisher?.pendingPermissionRequest {
            return "Permission required: \(permission.toolName)"
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
        return statusDescription
    }
    
    private var statusDescription: String {
        switch effectiveStatus {
        case .queued:
            return "Queued"
        case .waitingForVM:
            return "Waiting for VM"
        case .planning:
            return "Generating plan"
        case .planReview:
            return "Awaiting plan review"
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
    }
    
    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(task.title)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .lineLimit(1)
            
            Spacer()
            
            if needsIntervention {
                StatusPill(text: interventionPillText, color: .orange)
            } else {
                StatusPill(text: effectiveStatus.displayName, color: statusPillColor)
            }
        }
    }
    
    private var interventionPillText: String {
        if task.status == .planReview && !hasPendingQuestion && !hasPendingPermission {
            return "Needs review"
        }
        return "Needs input"
    }
    
    private var statusPillColor: Color {
        switch effectiveStatus {
        case .running: return .green
        case .paused, .queued, .waitingForVM, .planning: return .yellow
        case .planReview: return .blue
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
            
            if let screenshot = previewScreenshot {
                Image(nsImage: screenshot)
                    .resizable()
                    .scaledToFill()
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
            }
            
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

    private func handleCardTap() {
        if effectiveStatus == .planning || effectiveStatus == .planReview {
            showingPlanReview = true
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
        case .running, .paused:
            Task { await taskService.cancelTask(task) }
        default:
            break
        }
    }
}
