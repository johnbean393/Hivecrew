//
//  AgentEnvironmentsView.swift
//  Hivecrew
//
//  Agent Environments tab - Live view into running tasks and their ephemeral VMs
//

import Combine
import SwiftUI
import SwiftData
import TipKit
import AppKit
import HivecrewAPI
import HivecrewShared
import HivecrewCore

/// Represents an item in the environments sidebar (either a task or a developer VM)
enum EnvironmentItem: Hashable {
    case task(String)      // Task ID
    case developerVM(String) // VM ID
    
    var id: String {
        switch self {
        case .task(let taskId): return "task:\(taskId)"
        case .developerVM(let vmId): return "dev:\(vmId)"
        }
    }
}

/// Agent Environments tab - Live view into running tasks and their ephemeral VMs
struct AgentEnvironmentsView: View {
    @EnvironmentObject var vmService: VMServiceClient
    @EnvironmentObject var taskService: TaskService
    @ObservedObject private var vmRuntime = AppVMRuntime.shared
    
    @AppStorage("developerVMIds") private var developerVMIdsData: Data = Data()
    
    @Binding var selectedTaskId: String?
    @State private var selectedItem: EnvironmentItem?
    @State private var showProvisioningSheet = false
    @State private var showLocalTracePanel = true
    @State private var showRemoteTracePanel = true
    @State private var remoteCurrentTask: APITask?
    @State private var isPerformingRemoteAction = false
    
    // Tips
    private let takeControlTip = TakeControlTip()
    
    /// Developer VM IDs stored in settings
    private var developerVMIds: Set<String> {
        guard let decoded = try? JSONDecoder().decode(Set<String>.self, from: developerVMIdsData) else {
            return []
        }
        return decoded
    }
    
    /// Running developer VMs
    private var runningDeveloperVMs: [VMInfo] {
        vmService.vms.filter { vm in
            developerVMIds.contains(vm.id) && vmRuntime.getVM(id: vm.id) != nil
        }
    }
    
    var body: some View {
        NavigationSplitView {
            sidebarContent
        } detail: {
            detailContent
        }
        .toolbar { toolbarContent }
        .onChange(of: selectedItem) { _, newValue in
            // Sync with selectedTaskId for compatibility
            if case .task(let taskId) = newValue {
                selectedTaskId = taskId
            } else {
                selectedTaskId = nil
            }
            
            let selectedRemoteTaskId: String?
            if case .task(let taskId) = newValue,
               let task = activeTasksWithVMs.first(where: { $0.id == taskId }),
               task.isExecutingRemotely {
                selectedRemoteTaskId = taskId
            } else {
                selectedRemoteTaskId = nil
            }
            
            if remoteCurrentTask?.id != selectedRemoteTaskId {
                remoteCurrentTask = nil
                isPerformingRemoteAction = false
            }
        }
        .onChange(of: selectedTaskId) { _, newValue in
            // Sync from external selection
            if let taskId = newValue {
                selectedItem = .task(taskId)
            }
        }
        .onAppear {
            syncSelectionFromTaskIdIfNeeded()
            // Track environment viewed for tips when there are active tasks
            if !activeTasksWithVMs.isEmpty {
                TipStore.shared.donateEnvironmentViewed()
            }
        }
        .onChange(of: activeTasksWithVMs) { oldValue, newValue in
            // Track when a task becomes active
            if oldValue.isEmpty && !newValue.isEmpty {
                TipStore.shared.donateEnvironmentViewed()
            }
        }
    }
    
    // MARK: - Active Tasks
    
    /// Tasks that have an assigned VM (running or recently completed)
    private var activeTasksWithVMs: [TaskRecord] {
        taskService.tasks.filter { task in
            (task.assignedVMId != nil || task.isExecutingRemotely) &&
                taskService.isTaskEffectivelyActive(task)
        }.sorted { $0.createdAt > $1.createdAt }
    }
    
    // MARK: - Sidebar
    
    private var sidebarContent: some View {
        List(selection: $selectedItem) {
            // Active agent tasks section
            if !activeTasksWithVMs.isEmpty {
                Section("Agent Tasks") {
                    taskList
                }
            }
            
            // Developer VMs section
            if !runningDeveloperVMs.isEmpty {
                Section("Developer VMs") {
                    developerVMList
                }
            }
            
            // Empty state if nothing to show
            if activeTasksWithVMs.isEmpty && runningDeveloperVMs.isEmpty {
                emptyState
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 300)
        .safeAreaInset(edge: .bottom) {
            Button {
                showProvisioningSheet = true
            } label: {
                Label("VM Configuration", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .sheet(isPresented: $showProvisioningSheet) {
            VMProvisioningView()
        }
    }
    
    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Active Environments", systemImage: "desktopcomputer")
        } description: {
            Text("Start a task or developer VM to see it here")
        }
        .listRowBackground(Color.clear)
    }
    
    private var taskList: some View {
        ForEach(activeTasksWithVMs) { task in
            ActiveTaskRow(task: task)
                .tag(EnvironmentItem.task(task.id))
        }
    }
    
    private var developerVMList: some View {
        ForEach(runningDeveloperVMs) { vm in
            DeveloperVMRow(vm: vm)
                .tag(EnvironmentItem.developerVM(vm.id))
        }
    }
    
    // MARK: - Detail
    
    @ViewBuilder
    private var detailContent: some View {
        switch selectedItem {
        case .task(let taskId):
            if let task = activeTasksWithVMs.first(where: { $0.id == taskId }) {
                taskDetailView(for: task)
            } else {
                emptyDetailView
            }
            
        case .developerVM(let vmId):
            if let vmInfo = vmService.vms.first(where: { $0.id == vmId }) {
                VMDetailView(vm: vmInfo, showTracePanel: $showLocalTracePanel)
            } else {
                emptyDetailView
            }
            
        case nil:
            // Auto-select first available item
            if let firstTask = activeTasksWithVMs.first {
                taskDetailView(for: firstTask)
                    .onAppear { selectedItem = .task(firstTask.id) }
            } else if let firstDevVM = runningDeveloperVMs.first {
                VMDetailView(vm: firstDevVM, showTracePanel: $showLocalTracePanel)
                    .onAppear { selectedItem = .developerVM(firstDevVM.id) }
            } else {
                emptyDetailView
            }
        }
    }
    
    private var emptyDetailView: some View {
        ContentUnavailableView {
            Label("No Active Environments", systemImage: "desktopcomputer")
        } description: {
            Text("Running tasks and developer VMs will appear here")
        }
    }
    
    private func syncSelectionFromTaskIdIfNeeded() {
        guard let taskId = selectedTaskId else { return }
        if selectedItem != .task(taskId) {
            selectedItem = .task(taskId)
        }
    }
    
    @ViewBuilder
    private func taskDetailView(for task: TaskRecord) -> some View {
        if task.isExecutingRemotely {
            RemoteTaskDetailView(
                task: task,
                currentTask: $remoteCurrentTask,
                showTracePanel: $showRemoteTracePanel,
                isPerformingAction: $isPerformingRemoteAction
            )
        } else if let vmId = task.assignedVMId,
                  let vmInfo = vmService.vms.first(where: { $0.id == vmId }) {
            VMDetailView(vm: vmInfo, showTracePanel: $showLocalTracePanel)
                .popoverTip(takeControlTip, arrowEdge: .bottom)
        } else {
            emptyDetailView
        }
    }
    
    private var selectedTaskRecord: TaskRecord? {
        guard case .task(let taskId) = selectedItem else { return nil }
        return activeTasksWithVMs.first(where: { $0.id == taskId })
    }
    
    private var selectedLocalTask: TaskRecord? {
        if let task = selectedTaskRecord, !task.isExecutingRemotely {
            return task
        }
        
        guard case .developerVM(let vmId) = selectedItem else { return nil }
        return taskService.tasks.first { task in
            task.assignedVMId == vmId && taskService.isTaskEffectivelyActive(task)
        }
    }
    
    private var selectedLocalStatePublisher: AgentStatePublisher? {
        guard let task = selectedLocalTask else { return nil }
        return taskService.statePublisher(for: task.id)
    }
    
    private var selectedRemoteTask: TaskRecord? {
        guard let task = selectedTaskRecord, task.isExecutingRemotely else { return nil }
        return task
    }
    
    private var selectedRemoteStatus: APITaskStatus? {
        if let remoteCurrentTask {
            return remoteCurrentTask.status
        }
        guard let task = selectedRemoteTask else { return nil }
        return apiStatus(for: task.status)
    }
    
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if selectedRemoteTask != nil {
                remoteToolbarButtons
            } else {
                localToolbarButtons
            }
        }
    }
    
    @ViewBuilder
    private var localToolbarButtons: some View {
        if let task = selectedLocalTask, let publisher = selectedLocalStatePublisher {
            if publisher.status == .running {
                Button(action: pauseSelectedLocalTask) {
                    Label("Pause Agent", systemImage: "pause.fill")
                }
                .help("Pause the agent to take over manually")
            } else if publisher.status == .paused {
                Button(action: resumeSelectedLocalTask) {
                    Label("Resume Agent", systemImage: "play.fill")
                }
                .tint(.green)
                .help("Resume the agent")
            }
            
            if task.status.isActive {
                Button(action: cancelSelectedLocalTask) {
                    Label("Cancel", systemImage: "xmark.circle")
                }
                .tint(.red)
                .help("Cancel the task")
            }
            
            Button(action: { showLocalTracePanel.toggle() }) {
                Label("Trace", systemImage: "sidebar.trailing")
            }
            .help(showLocalTracePanel ? "Hide Trace Panel" : "Show Trace Panel")
        }
    }
    
    @ViewBuilder
    private var remoteToolbarButtons: some View {
        if selectedRemoteStatus == .running {
            Button(action: pauseSelectedRemoteTask) {
                Label("Pause Agent", systemImage: "pause.fill")
            }
            .disabled(isPerformingRemoteAction)
        } else if selectedRemoteStatus == .paused {
            Button(action: resumeSelectedRemoteTask) {
                Label("Resume Agent", systemImage: "play.fill")
            }
            .tint(.green)
            .disabled(isPerformingRemoteAction)
        }
        
        if let status = selectedRemoteStatus, status.isActive {
            Button(action: cancelSelectedRemoteTask) {
                Label("Cancel", systemImage: "xmark.circle")
            }
            .tint(.red)
            .disabled(isPerformingRemoteAction)
        }
        
        Button(action: { showRemoteTracePanel.toggle() }) {
            Label("Trace", systemImage: "sidebar.trailing")
        }
        .help(showRemoteTracePanel ? "Hide Trace Panel" : "Show Trace Panel")
    }
    
    private func pauseSelectedLocalTask() {
        guard let task = selectedLocalTask else { return }
        taskService.pauseTask(task)
    }
    
    private func resumeSelectedLocalTask() {
        guard let task = selectedLocalTask else { return }
        taskService.resumeTask(task)
    }
    
    private func cancelSelectedLocalTask() {
        guard let task = selectedLocalTask else { return }
        Task {
            await taskService.cancelTask(task)
        }
    }
    
    @MainActor
    private func pauseSelectedRemoteTask() {
        performRemoteAction(.pause)
    }
    
    @MainActor
    private func resumeSelectedRemoteTask() {
        performRemoteAction(.resume)
    }
    
    @MainActor
    private func cancelSelectedRemoteTask() {
        performRemoteAction(.cancel)
    }
    
    @MainActor
    private func performRemoteAction(_ action: APITaskAction, instructions: String? = nil) {
        guard let task = selectedRemoteTask else { return }
        
        isPerformingRemoteAction = true
        Task { @MainActor in
            defer { isPerformingRemoteAction = false }
            guard let provider = APIServerManager.shared.federatedProvider else { return }
            if let updatedTask = try? await provider.performTaskAction(id: task.id, action: action, instructions: instructions) {
                remoteCurrentTask = updatedTask
            }
        }
    }
    
    private func apiStatus(for status: TaskStatus) -> APITaskStatus {
        switch status {
        case .queued: return .queued
        case .waitingForVM: return .waitingForVM
        case .running: return .running
        case .paused: return .paused
        case .completed: return .completed
        case .failed: return .failed
        case .cancelled: return .cancelled
        case .timedOut: return .timedOut
        case .maxIterations: return .maxIterations
        case .planning: return .planning
        case .planReview: return .planReview
        case .planFailed: return .planFailed
        case .writebackReview: return .writebackReview
        }
    }
}

private struct RemoteTaskDetailView: View {
    let task: TaskRecord
    @Binding var currentTask: APITask?
    @Binding var showTracePanel: Bool
    @Binding var isPerformingAction: Bool
    @StateObject private var traceState: AgentStatePublisher
    @State private var screenshot: NSImage?
    @State private var since: Int = 0
    @State private var pollTask: Task<Void, Never>?
    @State private var instructionText: String = ""
    @State private var questionText: String = ""
    @State private var errorMessage: String?
    @State private var showingError = false

    init(
        task: TaskRecord,
        currentTask: Binding<APITask?>,
        showTracePanel: Binding<Bool>,
        isPerformingAction: Binding<Bool>
    ) {
        self.task = task
        _currentTask = currentTask
        _showTracePanel = showTracePanel
        _isPerformingAction = isPerformingAction
        _traceState = StateObject(wrappedValue: AgentStatePublisher(taskId: task.id, taskTitle: task.title))
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Group {
                    if let screenshot {
                        Image(nsImage: screenshot)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.black)
                    } else {
                        VStack(spacing: 8) {
                            ProgressView()
                            Text("Waiting for remote screenshot...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)
                    }
                }

                HStack(spacing: 16) {
                    Label(currentNodeName ?? "Remote node", systemImage: "desktopcomputer")
                    Spacer()
                    if let currentTask, let tokenUsage = currentTask.tokenUsage {
                        Text("\(formatNumber(tokenUsage.total)) tokens")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor))
            }

            if showTracePanel {
                Divider()
                RemoteAgentTracePanel(
                    task: currentTask,
                    fallbackTitle: task.title,
                    fallbackDescription: task.taskDescription,
                    statePublisher: traceState,
                    instructionText: $instructionText,
                    questionText: $questionText,
                    isPerformingAction: isPerformingAction,
                    onSendInstruction: submitInstruction,
                    onAnswerQuestion: answerQuestion,
                    onRespondToPermission: respondToPermission
                )
            }
        }
        .task(id: task.id) {
            startPolling()
        }
        .onDisappear {
            pollTask?.cancel()
            pollTask = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            startPolling()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            startPolling()
        }
        .alert("Error", isPresented: $showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    @MainActor
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                await poll()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    @MainActor
    private func poll() async {
        guard let provider = APIServerManager.shared.federatedProvider else { return }

        if let fetchedTask = try? await provider.getTask(id: task.id) {
            currentTask = fetchedTask
            traceState.taskTitle = fetchedTask.title
            traceState.status = fetchedTask.status.agentStatus
            traceState.currentStep = fetchedTask.stepCount ?? traceState.currentStep
            traceState.promptTokens = fetchedTask.tokenUsage?.prompt ?? 0
            traceState.completionTokens = fetchedTask.tokenUsage?.completion ?? 0
            traceState.totalTokens = fetchedTask.tokenUsage?.total ?? 0
        }

        if let remoteScreenshot = try? await provider.getTaskScreenshot(id: task.id),
           let image = NSImage(data: remoteScreenshot.data) {
            screenshot = image
            traceState.lastScreenshot = image
        }

        if let response = try? await provider.getTaskActivity(id: task.id, since: since) {
            if !response.events.isEmpty {
                traceState.activityLog.append(contentsOf: response.events.map(mapActivityEntry))
            }
            since = response.total
        }
    }

    private var currentNodeName: String? {
        currentTask?.nodeName ?? task.clusterPeerName
    }

    @MainActor
    private func submitInstruction() {
        let text = instructionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let action: APITaskAction = currentTask?.status == .paused ? .resume : .instruct
        instructionText = ""
        performAction(action, instructions: text)
    }

    @MainActor
    private func answerQuestion(_ answer: String) {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let question = currentTask?.pendingQuestion else { return }

        isPerformingAction = true
        Task { @MainActor in
            defer { isPerformingAction = false }
            do {
                guard let provider = APIServerManager.shared.federatedProvider else { return }
                try await provider.answerQuestion(taskId: task.id, questionId: question.id, answer: text)
                questionText = ""
                await poll()
            } catch {
                presentError(error)
            }
        }
    }

    @MainActor
    private func respondToPermission(approved: Bool) {
        guard let permission = currentTask?.pendingPermission else { return }

        isPerformingAction = true
        Task { @MainActor in
            defer { isPerformingAction = false }
            do {
                guard let provider = APIServerManager.shared.federatedProvider else { return }
                try await provider.respondToPermission(taskId: task.id, permissionId: permission.id, approved: approved)
                await poll()
            } catch {
                presentError(error)
            }
        }
    }

    @MainActor
    private func performAction(_ action: APITaskAction, instructions: String? = nil) {
        isPerformingAction = true
        Task { @MainActor in
            defer { isPerformingAction = false }
            do {
                guard let provider = APIServerManager.shared.federatedProvider else { return }
                currentTask = try await provider.performTaskAction(id: task.id, action: action, instructions: instructions)
                await poll()
            } catch {
                presentError(error)
            }
        }
    }

    @MainActor
    private func presentError(_ error: Error) {
        errorMessage = error.localizedDescription
        showingError = true
    }

    private func formatNumber(_ n: Int) -> String {
        if n >= 1000 {
            return String(format: "%.1fk", Double(n) / 1000.0)
        }
        return "\(n)"
    }

    private func mapActivityEntry(from event: APITaskEvent) -> AgentActivityEntry {
        AgentActivityEntry(
            id: "\(event.timestamp.timeIntervalSince1970)-\(event.type.rawValue)-\(UUID().uuidString)",
            timestamp: event.timestamp,
            type: event.type.activityType,
            summary: event.summaryText,
            details: event.detailsText
        )
    }
}

private struct RemoteAgentTracePanel: View {
    let task: APITask?
    let fallbackTitle: String
    let fallbackDescription: String
    @ObservedObject var statePublisher: AgentStatePublisher
    @Binding var instructionText: String
    @Binding var questionText: String
    let isPerformingAction: Bool
    let onSendInstruction: () -> Void
    let onAnswerQuestion: (String) -> Void
    let onRespondToPermission: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            taskHeader

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(statePublisher.activityLog) { entry in
                            TraceEntryView(entry: entry, statePublisher: statePublisher)
                                .id(entry.id)
                        }
                    }
                    .padding()
                }
                .scrollIndicators(.never)
                .onChange(of: statePublisher.activityLog.count) { oldCount, newCount in
                    if newCount > oldCount, let lastEntry = statePublisher.activityLog.last {
                        withAnimation {
                            proxy.scrollTo(lastEntry.id, anchor: .bottom)
                        }
                    }
                }
            }

            if let question = task?.pendingQuestion {
                Divider()
                questionInputView(question)
            }

            if let permission = task?.pendingPermission {
                Divider()
                permissionInputView(permission)
            }

            if task?.status == .running || task?.status == .paused {
                Divider()
                instructionInputBar
            }

            Divider()
            statusFooter
        }
        .frame(width: 380)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var taskHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(statusText)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(statusColor)

                Spacer()

                if let stepCount = task?.stepCount, stepCount > 0 {
                    Text("Step \(stepCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(Capsule())
                }
            }

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "person.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text(task?.title ?? fallbackTitle)
                        .font(.headline)
                        .lineLimit(2)

                    Text(task?.description ?? fallbackDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)

                    if let nodeName = task?.nodeName {
                        Text("Running on \(nodeName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .textSelection(.enabled)
            }
        }
        .padding()
    }

    private var instructionInputBar: some View {
        HStack(spacing: 8) {
            TextField("Add instructions...", text: $instructionText)
                .textFieldStyle(.roundedBorder)
                .onSubmit(onSendInstruction)

            Button(action: onSendInstruction) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(instructionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(isPerformingAction || instructionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func questionInputView(_ question: APIAgentQuestion) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble.fill")
                    .foregroundStyle(.yellow)
                Text("Agent is asking:")
                    .font(.subheadline)
                    .fontWeight(.medium)
            }

            Text(question.question)
                .font(.body)
                .foregroundStyle(.primary)

            if let suggestedAnswers = question.suggestedAnswers, !suggestedAnswers.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(suggestedAnswers, id: \.self) { answer in
                        Button(answer) {
                            onAnswerQuestion(answer)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isPerformingAction)
                    }
                }
            } else {
                HStack {
                    TextField("Type your answer...", text: $questionText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            onAnswerQuestion(questionText)
                        }

                    Button("Send") {
                        onAnswerQuestion(questionText)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isPerformingAction || questionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding()
        .background(Color.yellow.opacity(0.1))
    }

    private func permissionInputView(_ permission: APIPermissionRequest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.orange)
                Text("Permission Required")
                    .font(.subheadline)
                    .fontWeight(.medium)
            }

            Text(permission.toolName)
                .font(.body)
                .fontWeight(.medium)
            Text(permission.details)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            HStack(spacing: 12) {
                Button("Deny") {
                    onRespondToPermission(false)
                }
                .buttonStyle(.bordered)
                .disabled(isPerformingAction)

                Button("Allow") {
                    onRespondToPermission(true)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isPerformingAction)
            }
        }
        .padding()
        .background(Color.orange.opacity(0.1))
    }

    private var statusFooter: some View {
        HStack(spacing: 16) {
            if let totalTokens = task?.tokenUsage?.total, totalTokens > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "textformat.123")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("\(formatNumber(totalTokens)) tokens")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let nodeName = task?.nodeName {
                Text(nodeName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var statusColor: Color {
        (task?.status ?? .running).statusColor
    }

    private var statusText: String {
        (task?.status ?? .running).displayName
    }

    private func formatNumber(_ n: Int) -> String {
        if n >= 1000 {
            return String(format: "%.1fk", Double(n) / 1000.0)
        }
        return "\(n)"
    }
}

private extension APITaskStatus {
    var agentStatus: AgentStatus {
        switch self {
        case .queued, .waitingForVM, .planning, .planReview:
            return .connecting
        case .running:
            return .running
        case .paused:
            return .paused
        case .completed, .writebackReview:
            return .completed
        case .failed, .timedOut, .maxIterations, .planFailed:
            return .failed
        case .cancelled:
            return .cancelled
        }
    }

    var isActive: Bool {
        switch self {
        case .queued, .waitingForVM, .running, .paused, .planning, .planReview:
            return true
        case .completed, .failed, .cancelled, .timedOut, .maxIterations, .planFailed, .writebackReview:
            return false
        }
    }

    var displayName: String {
        switch self {
        case .queued:
            return "Queued"
        case .waitingForVM:
            return "Awaiting VM"
        case .running:
            return "Running"
        case .paused:
            return "Paused"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        case .timedOut:
            return "Timed Out"
        case .maxIterations:
            return "Max Iterations"
        case .planning:
            return "Planning"
        case .planReview:
            return "Review Plan"
        case .planFailed:
            return "Plan Failed"
        case .writebackReview:
            return "Review Changes"
        }
    }

    var statusColor: Color {
        switch self {
        case .queued, .waitingForVM, .paused, .planning:
            return .yellow
        case .running:
            return .green
        case .completed, .writebackReview:
            return .blue
        case .failed, .planFailed:
            return .red
        case .cancelled:
            return .orange
        case .timedOut, .maxIterations:
            return .orange
        case .planReview:
            return .blue
        }
    }
}

private extension APITaskEventType {
    var activityType: AgentActivityEntry.ActivityType {
        switch self {
        case .screenshot:
            return .observation
        case .toolCallStart:
            return .toolCall
        case .toolCallResult:
            return .toolResult
        case .llmResponse:
            return .llmResponse
        case .statusChange:
            return .info
        case .subagentUpdate:
            return .info
        case .question:
            return .userQuestion
        case .permissionRequest:
            return .userQuestion
        }
    }
}

private extension APITaskEvent {
    var summaryText: String {
        data.stringValue(for: "summary")
            ?? data.stringValue(for: "status")
            ?? data.stringValue(for: "tool")
            ?? defaultSummary
    }

    var detailsText: String? {
        if let details = data.stringValue(for: "details"), !details.isEmpty {
            return details
        }
        if let message = data.stringValue(for: "message"), !message.isEmpty {
            return message
        }
        if let question = data.stringValue(for: "question"), !question.isEmpty {
            return question
        }
        if let tool = data.stringValue(for: "tool"), let result = data.stringValue(for: "result") {
            return "\(tool): \(result)"
        }
        return nil
    }

    private var defaultSummary: String {
        switch type {
        case .screenshot:
            return "Captured screenshot"
        case .toolCallStart:
            return "Executing tool"
        case .toolCallResult:
            return "Tool completed"
        case .llmResponse:
            return "LLM response"
        case .statusChange:
            return "Status changed"
        case .subagentUpdate:
            return "Subagent update"
        case .question:
            return "Agent asked a question"
        case .permissionRequest:
            return "Permission requested"
        }
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    func stringValue(for key: String) -> String? {
        guard let value = self[key] else { return nil }
        switch value {
        case .string(let string):
            return string
        case .int(let int):
            return String(int)
        case .double(let double):
            return String(double)
        case .bool(let bool):
            return bool ? "true" : "false"
        case .null, .array, .object:
            return nil
        }
    }
}

#Preview {
    @Previewable @State var selectedTaskId: String? = nil
    AgentEnvironmentsView(selectedTaskId: $selectedTaskId)
        .environmentObject(VMServiceClient.shared)
        .environmentObject(TaskService())
}
