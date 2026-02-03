//
//  AgentPreviewStripView.swift
//  Hivecrew
//
//  Horizontal preview strip for active agents
//

import SwiftUI
import Combine

struct AgentPreviewStripView: View {
    @EnvironmentObject var taskService: TaskService
    @State private var sortEpoch: Int = 0
    
    private let cardWidth: CGFloat = 320
    private let cardHeight: CGFloat = 280
    private let previewHeight: CGFloat = 120
    
    var body: some View {
        let items = sortedItems()
        
        if items.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 16) {
                    ForEach(items) { item in
                        if let publisher = item.statePublisher {
                            AgentPreviewCardObserved(
                                task: item.task,
                                statePublisher: publisher,
                                cardWidth: cardWidth,
                                cardHeight: cardHeight,
                                previewHeight: previewHeight
                            )
                        } else {
                            AgentPreviewCardStatic(
                                task: item.task,
                                cardWidth: cardWidth,
                                cardHeight: cardHeight,
                                previewHeight: previewHeight
                            )
                        }
                    }
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.never)
            .frame(height: cardHeight + 32)
            .onReceive(refreshPublisher) { _ in
                sortEpoch += 1
            }
        }
    }
    
    private func sortedItems() -> [AgentPreviewItem] {
        let activeTasks = taskService.tasks.filter { $0.status.isActive }
        let items = activeTasks.map { task in
            let publisher = taskService.statePublishers[task.id]
            return AgentPreviewItem(
                task: task,
                statePublisher: publisher,
                interventionTimestamp: interventionTimestamp(for: publisher)
            )
        }
        
        return items.sorted { lhs, rhs in
            let lhsKey = sortKey(for: lhs)
            let rhsKey = sortKey(for: rhs)
            if lhsKey.group != rhsKey.group {
                return lhsKey.group < rhsKey.group
            }
            if lhsKey.date != rhsKey.date {
                return lhsKey.date < rhsKey.date
            }
            return lhs.task.createdAt < rhs.task.createdAt
        }
    }
    
    private func sortKey(for item: AgentPreviewItem) -> (group: Int, date: Date) {
        if let interventionTimestamp = item.interventionTimestamp {
            return (0, interventionTimestamp)
        }
        
        if item.task.status == .planReview {
            return (0, item.task.createdAt)
        }
        
        switch item.task.status {
        case .running:
            return (1, item.task.startedAt ?? item.task.createdAt)
        case .paused:
            return (2, item.task.createdAt)
        case .queued, .waitingForVM, .planning:
            return (3, item.task.createdAt)
        case .planReview:
            return (0, item.task.createdAt)
        case .completed, .failed, .cancelled, .timedOut, .maxIterations, .planFailed:
            return (4, item.task.createdAt)
        }
    }
    
    private func interventionTimestamp(for publisher: AgentStatePublisher?) -> Date? {
        guard let publisher = publisher else { return nil }
        var timestamps: [Date] = []
        if let question = publisher.pendingQuestion {
            timestamps.append(question.createdAt)
        }
        if let permission = publisher.pendingPermissionRequest {
            timestamps.append(permission.createdAt)
        }
        return timestamps.min()
    }
    
    private var refreshPublisher: AnyPublisher<Void, Never> {
        let publishers = taskService.statePublishers.values.flatMap { publisher in
            [
                publisher.$pendingQuestion.map { _ in () }.eraseToAnyPublisher(),
                publisher.$pendingPermissionRequest.map { _ in () }.eraseToAnyPublisher(),
                publisher.$lastScreenshot.map { _ in () }.eraseToAnyPublisher()
            ]
        }
        
        guard !publishers.isEmpty else {
            return Empty().eraseToAnyPublisher()
        }
        
        return Publishers.MergeMany(publishers).eraseToAnyPublisher()
    }
}

private struct AgentPreviewItem: Identifiable {
    let task: TaskRecord
    let statePublisher: AgentStatePublisher?
    let interventionTimestamp: Date?
    
    var id: String { task.id }
}

private struct AgentPreviewCardObserved: View {
    let task: TaskRecord
    @ObservedObject var statePublisher: AgentStatePublisher
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let previewHeight: CGFloat
    @State private var latestScreenshot: NSImage?
    
    var body: some View {
        AgentPreviewCardContent(
            task: task,
            statePublisher: statePublisher,
            cardWidth: cardWidth,
            cardHeight: cardHeight,
            previewHeight: previewHeight,
            previewScreenshot: previewScreenshot,
            previewScreenshotPath: statePublisher.lastScreenshotPath
        )
        .onAppear {
            latestScreenshot = statePublisher.lastScreenshot
        }
        .onReceive(statePublisher.$lastScreenshot) { newScreenshot in
            latestScreenshot = newScreenshot
        }
    }
    
    private var previewScreenshot: NSImage? {
        if let latestScreenshot = latestScreenshot {
            return latestScreenshot
        }
        if let path = statePublisher.lastScreenshotPath {
            return NSImage(contentsOfFile: path)
        }
        return nil
    }
}

private struct AgentPreviewCardStatic: View {
    let task: TaskRecord
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let previewHeight: CGFloat
    
    var body: some View {
        AgentPreviewCardContent(
            task: task,
            statePublisher: nil,
            cardWidth: cardWidth,
            cardHeight: cardHeight,
            previewHeight: previewHeight,
            previewScreenshot: nil,
            previewScreenshotPath: nil
        )
    }
}

private struct AgentPreviewCardContent: View {
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
        switch task.status {
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
                StatusPill(text: task.status.displayName, color: statusPillColor)
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
        switch task.status {
        case .running: return .green
        case .paused, .queued, .waitingForVM, .planning: return .yellow
        case .planReview: return .blue
        case .failed, .planFailed: return .red
        case .cancelled: return .gray
        case .timedOut, .maxIterations: return .orange
        case .completed: return .secondary
        }
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
            if task.status == .running {
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
            } else if task.status == .paused {
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
            } else if task.status == .planReview {
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
        if task.status == .planning || task.status == .planReview {
            showingPlanReview = true
        } else if task.status == .running || task.status == .paused {
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
        switch task.status {
        case .queued, .waitingForVM:
            return "Remove from queue"
        case .planning, .planReview:
            return "Cancel planning"
        default:
            return "Stop agent"
        }
    }
    
    private func stopTask() {
        switch task.status {
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

private struct StatusPill: View {
    let text: String
    let color: Color
    
    var body: some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(color.opacity(0.15))
            )
    }
}

private extension AgentQuestion {
    var createdAt: Date {
        switch self {
        case .text(let question):
            return question.createdAt
        case .multipleChoice(let question):
            return question.createdAt
        case .intervention(let request):
            return request.createdAt
        }
    }
}
