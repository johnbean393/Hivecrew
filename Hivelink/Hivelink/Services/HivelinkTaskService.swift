//
//  HivelinkTaskService.swift
//  Hivelink
//
//  SwiftData-backed task list, remote dispatch host, and peer task actions.
//

import ActivityKit
import Combine
import CoreSpotlight
import Foundation
import HivecrewAPIModels
import HivecrewCore
import HivecrewShared
import SwiftData
import UIKit
import UniformTypeIdentifiers
import WidgetKit

// MARK: - Task service

@MainActor
final class HivelinkTaskService: ObservableObject, TaskServiceProtocol, RemoteTaskDispatchHost {
    private static let taskAttachmentsDirectoryName = "TaskAttachments"

    private enum TaskCreationPreparationError: LocalizedError {
        case missingContinuationSource(taskId: String)
        case failedToImportContinuationArtifacts(taskTitle: String, detail: String?)

        var errorDescription: String? {
            switch self {
            case .missingContinuationSource(let taskId):
                return "Could not continue from task \(taskId) because it is no longer available locally."
            case .failedToImportContinuationArtifacts(let taskTitle, let detail):
                if let detail, !detail.isEmpty {
                    return "Could not prepare continuation artifacts for \"\(taskTitle)\": \(detail)"
                }
                return "Could not prepare continuation artifacts for \"\(taskTitle)\"."
            }
        }
    }

    private let modelContext: ModelContext
    private(set) weak var clusterCoordinator: HivelinkClusterCoordinator?

    @Published private(set) var tasks: [TaskRecord] = []

    private(set) var remoteTaskIndex: RemoteTaskIndex
    private(set) var dispatcher: RemoteTaskDispatcher!

    let artifactImportCoordinator = ArtifactImportCoordinator()

    /// Real-time SSE + screenshot monitoring for active remote tasks (owned by `HivelinkAppCore`).
    weak var peerConnectionManager: PeerConnectionManager?

    /// Posts local notifications for task state changes (owned by `HivelinkAppCore`).
    weak var notificationManager: NotificationManager?

    /// Triggers incoming CallKit calls for task events (owned by `HivelinkAppCore`).
    weak var incomingCallManager: IncomingCallManager?

    /// Long-running reconciliation loop; cancelled in `stopReconciliation()` (cannot use `Timer` + `deinit` with `@MainActor` isolation).
    private var reconciliationTask: Task<Void, Never>?

    /// Tracks Live Activities for running tasks, keyed by `TaskRecord.id`.
    private var liveActivities: [String: Activity<TaskActivityAttributes>] = [:]

    /// Task IDs that already triggered a terminal haptic, to avoid repeating.
    private var terminalHapticFired: Set<String> = []

    /// Previous task statuses, used to detect transitions that warrant incoming calls.
    private var previousStatuses: [String: TaskStatus] = [:]

    /// Task IDs that already triggered an incoming call, to avoid repeating.
    private var callTriggeredTaskIds: Set<String> = []
    private static let callTriggeredIdsKey = "HivelinkTaskService.callTriggeredTaskIds"

    init(
        modelContext: ModelContext,
        clusterCoordinator: HivelinkClusterCoordinator,
        remoteTaskIndex: RemoteTaskIndex
    ) {
        self.modelContext = modelContext
        self.clusterCoordinator = clusterCoordinator
        self.remoteTaskIndex = remoteTaskIndex
        self.dispatcher = RemoteTaskDispatcher(
            host: self,
            clusterDirectory: clusterCoordinator,
            remoteTaskIndex: remoteTaskIndex
        )
        if let stored = UserDefaults.standard.array(forKey: Self.callTriggeredIdsKey) as? [String] {
            callTriggeredTaskIds = Set(stored)
        }
        loadTasks()
    }

    // MARK: - Bootstrap & reconciliation

    func bootstrap() async {
        await dispatcher.bootstrapRemoteReconciliation()
        startReconciliation()
    }

    func stopReconciliation() {
        reconciliationTask?.cancel()
        reconciliationTask = nil
        peerConnectionManager?.stopAll()
    }

    /// Reloads tasks from the SwiftData store (e.g. pull-to-refresh).
    func refreshTaskList() {
        refreshTasks()
    }

    /// Removes all local task records and task-owned artifacts after account deletion.
    func wipeAllLocalData() async {
        stopReconciliation()
        notificationManager?.removeAllTaskNotifications()

        let existingTasks = tasks
        let taskIds = existingTasks.map(\.id)
        for task in existingTasks {
            modelContext.delete(task)
        }
        try? modelContext.save()

        let entries = await remoteTaskIndex.allEntries()
        for entry in entries {
            await remoteTaskIndex.remove(canonicalTaskId: entry.canonicalTaskId)
        }
        dispatcher.invalidatePeerClientCache()

        tasks = []
        previousStatuses.removeAll()
        terminalHapticFired.removeAll()
        callTriggeredTaskIds.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.callTriggeredIdsKey)

        if !taskIds.isEmpty {
            try? await CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: taskIds)
        }

        clearLocalTaskFiles()
        syncLiveActivities()
        SharedDataWriter.writeTaskSummaries([])
        SharedDataWriter.writeClusterStatus(
            SharedClusterStatus(
                peerCount: 0,
                onlinePeerCount: 0,
                totalAvailableSlots: 0,
                totalRunningTasks: 0
            )
        )
        SharedDataWriter.reloadWidgets()
        VoIPDiagnosticsLog.clear()
    }

    /// Runs one remote reconciliation pass and refreshes the local task list.
    func reconcileAndRefresh() async {
        await dispatcher.reconcileRemoteTasks()
        refreshTasks()
        await peerConnectionManager?.syncMonitoring(tasks: tasks)
        writeSharedDataForWidgets()
        indexAllTasksInSpotlight()
    }

    /// Starts monitoring (screenshot + events + questions) for a single task
    /// without waiting for a full remote reconciliation pass.
    func ensureMonitoring(for task: TaskRecord) async {
        await peerConnectionManager?.ensureMonitoring(for: task)
    }

    private func startReconciliation() {
        reconciliationTask?.cancel()
        reconciliationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.dispatcher.reconcileRemoteTasks()
                await self.dispatcher.retryQueuedTasks()
                await self.peerConnectionManager?.syncMonitoring(tasks: self.tasks)
                self.writeSharedDataForWidgets()
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                } catch {
                    break
                }
            }
        }
    }

    // MARK: - TaskServiceProtocol

    func createTasks(_ requests: [TaskCreationRequest]) async throws -> [TaskRecord] {
        guard !requests.isEmpty else { return [] }

        let preparedRequests = try await prepareRequestsForCreation(requests)

        for (index, existing) in tasks.enumerated() {
            existing.sortOrder = index + preparedRequests.count
        }

        var created: [TaskRecord] = []
        created.reserveCapacity(preparedRequests.count)

        for (index, request) in preparedRequests.enumerated() {
            let title = Self.placeholderTitle(from: request.description)

            let persistedExecutionTarget: TaskExecutionTarget = {
                switch request.executionTarget.kind {
                case .peer:
                    return request.executionTarget
                case .automatic, .remoteFirst, .local:
                    return .remoteFirst
                }
            }()

            let mergedPaths = Array(Set(request.attachedFilePaths + request.retrievalContextAttachmentPaths)).sorted()
            let preparedAttachmentInfos: [AttachmentInfo]?
            if let existing = request.attachmentInfos {
                preparedAttachmentInfos = existing
            } else if !mergedPaths.isEmpty {
                preparedAttachmentInfos = mergedPaths.map { AttachmentInfo(path: $0) }
            } else {
                preparedAttachmentInfos = nil
            }

            let task = TaskRecord(
                id: request.taskId ?? UUID().uuidString,
                title: title,
                taskDescription: request.description,
                status: .queued,
                sortOrder: index,
                providerId: request.providerId,
                modelId: request.modelId,
                executionTarget: persistedExecutionTarget,
                runtimeTarget: request.runtimeTarget,
                reasoningEnabled: request.reasoningEnabled,
                reasoningEffort: request.reasoningEffort,
                serviceTier: request.serviceTier,
                attachmentInfos: preparedAttachmentInfos,
                outputDirectory: request.outputDirectory,
                mentionedSkillNames: request.mentionedSkillNames.isEmpty ? nil : request.mentionedSkillNames,
                referencedTaskIds: request.referencedTaskIds.isEmpty ? nil : request.referencedTaskIds,
                continuationSourceTaskId: request.continuationSourceTaskId,
                retrievalContextPackId: request.retrievalContextPackId,
                retrievalInlineContextBlocks: request.retrievalInlineContextBlocks,
                retrievalContextAttachmentPaths: request.retrievalContextAttachmentPaths.isEmpty
                    ? nil
                    : request.retrievalContextAttachmentPaths,
                retrievalSelectedSuggestionIds: request.retrievalSelectedSuggestionIds.isEmpty
                    ? nil
                    : request.retrievalSelectedSuggestionIds,
                retrievalModeOverrides: request.retrievalModeOverrides.isEmpty ? nil : request.retrievalModeOverrides,
                clusterReferenceContextBlocks: request.clusterReferenceContextBlocks,
                clusterReferenceFiles: request.clusterReferenceFiles,
                planFirstEnabled: request.planFirstEnabled,
                planMarkdown: request.planMarkdown,
                planSelectedSkillNames: request.planSelectedSkillNames,
                localAccessGrants: request.localAccessGrants,
                clusterOwnerTaskId: request.clusterOwnerTaskId,
                clusterExecutionAttempt: request.clusterExecutionAttempt,
                clusterLeaseId: request.clusterLeaseId
            )

            if request.planMarkdown != nil {
                task.planMarkdown = request.planMarkdown
                task.planSelectedSkillNames = request.planSelectedSkillNames
            }

            persistAttachmentsToDisk(for: task)

            modelContext.insert(task)
            created.append(task)
        }

        try modelContext.save()
        refreshTasks()
        HapticManager.taskCreated()

        for task in created {
            indexTaskInSpotlight(task)
            Task {
                await dispatcher.dispatchQueuedCanonicalTaskToPeer(task)
            }
        }

        return created
    }

    func deleteTask(_ task: TaskRecord) {
        let taskId = task.id
        modelContext.delete(task)
        try? modelContext.save()
        refreshTasks()
        removeTaskFromSpotlight(taskId)
        Task {
            await remoteTaskIndex.remove(canonicalTaskId: taskId)
        }
    }

    func renameTask(_ task: TaskRecord, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, task.title != trimmed else { return }
        task.title = trimmed
        try? modelContext.save()
        refreshTasks()
    }

    func cancelTask(_ task: TaskRecord) async {
        let hasPeer = await remoteTaskIndex.peerId(for: task.id) != nil
        if !hasPeer && task.status == .queued {
            task.status = .cancelled
            try? modelContext.save()
            refreshTasks()
            return
        }
        await performPeerAction(task, action: "cancel")
    }

    func pauseTask(_ task: TaskRecord) async {
        await performPeerAction(task, action: "pause")
    }

    func resumeTask(_ task: TaskRecord) async {
        await performPeerAction(task, action: "resume")
    }

    func executePlan(for task: TaskRecord) async {
        await performPeerAction(task, action: "approve_plan")
    }

    func cancelPlanning(for task: TaskRecord) async {
        await performPeerAction(task, action: "cancel_plan")
    }

    func approveWriteback(for task: TaskRecord) async {
        await performPeerAction(task, action: "approve_writeback")
    }

    func discardWriteback(for task: TaskRecord) async {
        await performPeerAction(task, action: "discard_writeback")
    }

    func sendInstruction(_ instruction: String, to task: TaskRecord) async {
        await performPeerAction(task, action: "instruct", instructions: instruction)
    }

    func answerQuestion(_ task: TaskRecord, questionId: String, answer: String) async {
        guard let peerId = await remoteTaskIndex.peerId(for: task.id),
              let workerTaskId = await remoteTaskIndex.workerTaskId(for: task.id),
              let coordinator = clusterCoordinator,
              let peer = await coordinator.peer(id: peerId)
        else { return }

        let client = await dispatcher.peerClient(for: peer)
        try? await client.answerQuestion(taskId: workerTaskId, questionId: questionId, answer: answer)
    }

    func respondToPermission(_ task: TaskRecord, permissionId: String, approved: Bool) async {
        guard let peerId = await remoteTaskIndex.peerId(for: task.id),
              let workerTaskId = await remoteTaskIndex.workerTaskId(for: task.id),
              let coordinator = clusterCoordinator,
              let peer = await coordinator.peer(id: peerId)
        else { return }

        let client = await dispatcher.peerClient(for: peer)
        try? await client.respondToPermission(taskId: workerTaskId, permissionId: permissionId, approved: approved)
    }

    func getTask(byId id: String) -> TaskRecord? {
        tasks.first { $0.id == id }
    }

    // MARK: - RemoteTaskDispatchHost

    func allTasks() -> [TaskRecord] {
        tasks
    }

    func taskRecord(id: String) -> TaskRecord? {
        tasks.first { $0.id == id }
    }

    func getProviderName(for providerId: String) -> String {
        if providerId.hasPrefix(TaskRecord.remoteOnlyProviderPrefix) {
            let raw = String(providerId.dropFirst(TaskRecord.remoteOnlyProviderPrefix.count))
            return raw.isEmpty ? "Unknown" : raw
        }
        return providerId.isEmpty ? "Unknown" : providerId
    }

    func convertToAPITask(_ task: TaskRecord) -> APITask {
        let providerName = getProviderName(for: task.providerId)
        let inputFiles = apiInputFiles(for: task)
        let outputFiles = apiOutputFiles(for: task)

        return APITask(
            id: task.id,
            title: task.title,
            description: task.taskDescription,
            status: convertToAPIStatus(task.status),
            providerName: providerName,
            modelId: task.modelId,
            reasoningEnabled: task.reasoningEnabled,
            reasoningEffort: task.reasoningEffort,
            createdAt: task.createdAt,
            startedAt: task.startedAt,
            completedAt: task.completedAt,
            resultSummary: task.resultSummary,
            errorMessage: task.errorMessage,
            inputFiles: inputFiles,
            outputFiles: outputFiles,
            wasSuccessful: task.wasSuccessful,
            vmId: task.assignedVMId,
            referencedTaskIds: task.referencedTaskIds,
            continuationSourceTaskId: task.continuationSourceTaskId,
            duration: task.startedAt.map { Int(Date().timeIntervalSince($0)) },
            stepCount: nil,
            tokenUsage: nil,
            planMarkdown: task.planMarkdown,
            planFirst: task.planFirstEnabled,
            contextPackId: task.retrievalContextPackId,
            contextItemCount: task.retrievalSelectedSuggestionIds?.count,
            contextAttachmentCount: task.retrievalContextAttachmentPaths?.count,
            pendingQuestion: nil,
            pendingPermission: nil,
            pendingWriteback: task.pendingWritebackOperations.isEmpty
                ? nil
                : APIPendingWriteback(count: task.pendingWritebackOperations.count, hasConflicts: false),
            pendingWritebackCount: task.pendingWritebackOperations.count,
            appliedWritebackPaths: task.appliedWritebackPaths,
            nodeId: task.clusterPeerId,
            nodeName: task.clusterPeerName
        )
    }

    func convertFromAPIStatus(_ status: APITaskStatus) -> TaskStatus {
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

    func saveModelContext() throws {
        try modelContext.save()
    }

    func notifyTaskListChanged() {
        refreshTasks()
    }

    func localAvailableSlotsForDispatchDecision() async -> Int? {
        0
    }

    func ownerDisplayName() -> String? {
        UIDevice.current.name
    }

    func materializeTaskReferences(for task: TaskRecord, referencesRoot: URL) throws -> [String] {
        let referencedTasks = resolvedDirectReferencedTasks(for: task)
        guard !referencedTasks.isEmpty else {
            try? FileManager.default.removeItem(at: referencesRoot)
            return []
        }

        let fm = FileManager.default
        if fm.fileExists(atPath: referencesRoot.path) {
            try fm.removeItem(at: referencesRoot)
        }
        try fm.createDirectory(at: referencesRoot, withIntermediateDirectories: true)

        var copiedFileSources: [String: URL] = [:]
        var usedBundleNames = Set<String>()
        var inlineContextBlocks: [String] = []

        for referencedTask in referencedTasks {
            let bundleName = uniqueReferenceBundleName(for: referencedTask, usedNames: &usedBundleNames)
            let bundleRoot = referencesRoot.appendingPathComponent(bundleName, isDirectory: true)
            let inboxRoot = bundleRoot.appendingPathComponent("inbox", isDirectory: true)
            let outboxRoot = bundleRoot.appendingPathComponent("outbox", isDirectory: true)
            let workspaceRoot = bundleRoot.appendingPathComponent("workspace", isDirectory: true)

            try fm.createDirectory(at: inboxRoot, withIntermediateDirectories: true)
            try fm.createDirectory(at: outboxRoot, withIntermediateDirectories: true)
            try fm.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)

            try copyReferenceFiles(
                from: referencedTask.attachmentInfos.map(\.effectivePath),
                to: inboxRoot,
                copiedFileSources: &copiedFileSources
            )
            try copyReferenceFiles(
                from: referencedTask.outputFilePaths ?? [],
                to: outboxRoot,
                copiedFileSources: &copiedFileSources
            )
            try copyReferenceWorkspace(
                from: referencedTask.sessionId,
                to: workspaceRoot
            )

            let ancestorTasks = resolvedAncestorReferencedTasks(for: referencedTask)
            let guestBundlePath = "~/Desktop/workspace/references/\(bundleName)"
            let contextMarkdown = taskReferenceContextMarkdown(
                for: referencedTask,
                ancestorTasks: ancestorTasks,
                guestBundlePath: guestBundlePath
            )
            try contextMarkdown.write(
                to: bundleRoot.appendingPathComponent("context.md"),
                atomically: true,
                encoding: .utf8
            )

            inlineContextBlocks.append(
                """
                Previous task "\(referencedTask.title)" has been materialized at `\(guestBundlePath)`.
                Review `\(guestBundlePath)/context.md` for prompt history and provenance.
                Reuse files from `\(guestBundlePath)/inbox/`, `\(guestBundlePath)/outbox/`, and `\(guestBundlePath)/workspace/` as needed.
                """
            )
        }

        return inlineContextBlocks
    }

    func importCompletedRemoteArtifacts(
        task: TaskRecord,
        peer: RemoteClusterPeer,
        workerTaskId: String,
        remoteTask: APITask,
        client: PeerAPIClient
    ) async -> Bool {
        let success = await artifactImportCoordinator.importArtifacts(
            task: task,
            peer: peer,
            workerTaskId: workerTaskId,
            remoteTask: remoteTask,
            client: client
        )
        if success {
            try? modelContext.save()
        }
        return success
    }

    // MARK: - Live Activities

    private func syncLiveActivities() {
        let now = Date()

        // Re-adopt any system-owned activities from prior launches that we
        // lost track of (e.g. after the app was killed and relaunched).
        for systemActivity in Activity<TaskActivityAttributes>.activities {
            let taskId = systemActivity.attributes.taskId
            if liveActivities[taskId] == nil {
                liveActivities[taskId] = systemActivity
            }
        }

        // Build a set of task IDs that should have an active Live Activity.
        let wantActiveIds: Set<String> = Set(
            tasks
                .filter { [.running, .planning, .paused, .waitingForVM].contains($0.status) }
                .map(\.id)
        )

        for task in tasks {
            let pendingQuestion = peerConnectionManager?.pendingQuestion(for: task.id)
            let needsAttention = task.status == .paused || task.status == .planReview || task.status == .writebackReview || pendingQuestion != nil
            let attentionMessage: String? = needsAttention ? (pendingQuestion?.question ?? task.status.displayName) : nil

            let attentionKind: AttentionKind?
            let attentionActionId: String?
            var suggestedReplies: [String]?

            if let question = pendingQuestion {
                attentionKind = .question
                attentionActionId = question.id
                suggestedReplies = Array((question.suggestedAnswers ?? []).prefix(2))
            } else {
                switch task.status {
                case .planReview:
                    attentionKind = .plan
                    attentionActionId = nil
                case .writebackReview:
                    attentionKind = .writeback
                    attentionActionId = nil
                default:
                    attentionKind = nil
                    attentionActionId = nil
                }
            }

            let contentState = TaskActivityAttributes.ContentState(
                status: task.status.displayName,
                completionPercent: todoCompletionPercent(for: task),
                stepCount: nil,
                needsAttention: needsAttention,
                attentionMessage: attentionMessage,
                attentionKind: attentionKind,
                attentionActionId: attentionActionId,
                suggestedReplies: suggestedReplies
            )

            if wantActiveIds.contains(task.id) {
                if let activity = liveActivities[task.id] {
                    let content = ActivityContent(state: contentState, staleDate: now.addingTimeInterval(15))
                    nonisolated(unsafe) let sendableActivity = activity
                    Task { await sendableActivity.update(content) }
                } else {
                    startLiveActivity(for: task, state: contentState)
                }
            } else if task.status.isTerminal {
                if terminalHapticFired.insert(task.id).inserted {
                    switch task.status {
                    case .completed:
                        HapticManager.taskCompleted()
                    case .failed, .timedOut, .maxIterations, .planFailed:
                        HapticManager.taskFailed()
                    default:
                        break
                    }
                }
                if let activity = liveActivities.removeValue(forKey: task.id) {
                    let finalContent = ActivityContent(state: contentState, staleDate: nil)
                    nonisolated(unsafe) let sendableActivity = activity
                    Task { await sendableActivity.end(finalContent, dismissalPolicy: .immediate) }
                }
            }
        }

        // End any tracked activities whose task no longer exists in the list.
        let knownTaskIds = Set(tasks.map(\.id))
        for (taskId, activity) in liveActivities where !knownTaskIds.contains(taskId) {
            liveActivities.removeValue(forKey: taskId)
            let endState = TaskActivityAttributes.ContentState(
                status: "Removed",
                completionPercent: nil,
                stepCount: nil,
                needsAttention: false,
                attentionMessage: nil,
                attentionKind: nil,
                attentionActionId: nil,
                suggestedReplies: nil
            )
            let finalContent = ActivityContent(state: endState, staleDate: nil)
            nonisolated(unsafe) let sendableActivity = activity
            Task { await sendableActivity.end(finalContent, dismissalPolicy: .immediate) }
        }

        // End any system activities we never adopted (e.g. for a task ID we
        // already handled as terminal above but that the system still holds).
        for systemActivity in Activity<TaskActivityAttributes>.activities {
            let taskId = systemActivity.attributes.taskId
            if !wantActiveIds.contains(taskId) {
                nonisolated(unsafe) let sendableActivity = systemActivity
                let endState = TaskActivityAttributes.ContentState(
                    status: "Ended",
                    completionPercent: nil,
                    stepCount: nil,
                    needsAttention: false,
                    attentionMessage: nil,
                    attentionKind: nil,
                    attentionActionId: nil,
                    suggestedReplies: nil
                )
                let finalContent = ActivityContent(state: endState, staleDate: nil)
                Task { await sendableActivity.end(finalContent, dismissalPolicy: .immediate) }
            }
        }
    }

    private func todoCompletionPercent(for task: TaskRecord) -> Int? {
        guard let plan = task.planMarkdown, !plan.isEmpty else { return nil }

        let pattern = #"^\s*-\s*\[([ xX])\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else { return nil }

        let lines = plan.components(separatedBy: .newlines)
        var total = 0
        var preCompleted = 0
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            if let match = regex.firstMatch(in: line, range: range),
               let stateRange = Range(match.range(at: 1), in: line) {
                total += 1
                if line[stateRange].lowercased() == "x" { preCompleted += 1 }
            }
        }
        guard total > 0 else { return nil }

        let events = peerConnectionManager?.events(for: task.id) ?? []
        let finishCount = events.filter { event in
            guard event.type == .toolCallResult else { return false }
            let toolName = event.data["tool_name"]?.stringValue ?? ""
            let summary = event.data["summary"]?.stringValue ?? ""
            return toolName.contains("finish_todo")
                || summary.contains("Plan item completed")
                || (summary.contains("todo") && summary.contains("completed"))
        }.count

        let completed = min(preCompleted + finishCount, total)
        return Int((Double(completed) / Double(total)) * 100)
    }

    private func startLiveActivity(for task: TaskRecord, state: TaskActivityAttributes.ContentState) {
        // Don't create a new one if the system already has an activity for this task
        // (possible race with the re-adoption pass above).
        if Activity<TaskActivityAttributes>.activities.contains(where: { $0.attributes.taskId == task.id }) {
            for existing in Activity<TaskActivityAttributes>.activities where existing.attributes.taskId == task.id {
                liveActivities[task.id] = existing
                return
            }
        }

        let attributes = TaskActivityAttributes(
            taskId: task.id,
            taskTitle: task.title,
            peerName: task.clusterPeerName ?? "",
            createdAt: task.createdAt
        )
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(15))

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
            liveActivities[task.id] = activity
        } catch {
            // Live Activities may be disabled or unavailable
        }
    }

    // MARK: - Shared data for widgets

    func writeSharedDataForWidgets() {
        let summaries = tasks.map { task in
            SharedTaskSummary(
                id: task.id,
                title: task.title,
                statusName: task.status.displayName,
                statusColor: task.status.statusColor,
                peerName: task.clusterPeerName,
                startedAt: task.startedAt,
                isActive: task.status.isActive
            )
        }
        SharedDataWriter.writeTaskSummaries(summaries)

        if let coordinator = clusterCoordinator {
            let peers = coordinator.peers
            let onlineCount = peers.filter { $0.status == .online }.count
            let onlinePeers = peers.filter { $0.status == .online }
            let totalSlots = onlinePeers.reduce(0) { $0 + $1.availableSlots }
            let totalRunning = onlinePeers.reduce(0) { $0 + $1.runningTasks }
            let cluster = SharedClusterStatus(
                peerCount: peers.count,
                onlinePeerCount: onlineCount,
                totalAvailableSlots: totalSlots,
                totalRunningTasks: totalRunning
            )
            SharedDataWriter.writeClusterStatus(cluster)
        }

        SharedDataWriter.reloadWidgets()
    }

    // MARK: - Spotlight Indexing

    func indexTaskInSpotlight(_ task: TaskRecord) {
        let attributeSet = CSSearchableItemAttributeSet(contentType: .text)
        attributeSet.title = task.title
        attributeSet.contentDescription = task.taskDescription
        attributeSet.keywords = [task.status.displayName]

        let item = CSSearchableItem(
            uniqueIdentifier: task.id,
            domainIdentifier: "tasks",
            attributeSet: attributeSet
        )
        CSSearchableIndex.default().indexSearchableItems([item])
    }

    func indexAllTasksInSpotlight() {
        let items = tasks.map { task -> CSSearchableItem in
            let attributeSet = CSSearchableItemAttributeSet(contentType: .text)
            attributeSet.title = task.title
            attributeSet.contentDescription = task.taskDescription
            attributeSet.keywords = [task.status.displayName]
            return CSSearchableItem(
                uniqueIdentifier: task.id,
                domainIdentifier: "tasks",
                attributeSet: attributeSet
            )
        }
        guard !items.isEmpty else { return }
        CSSearchableIndex.default().indexSearchableItems(items)
    }

    private func removeTaskFromSpotlight(_ taskId: String) {
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: [taskId])
    }

    // MARK: - Private helpers

    private func loadTasks() {
        refreshTasks()
    }

    private func clearLocalTaskFiles() {
        let fm = FileManager.default
        let directories = [
            AppPaths.sessionsDirectory,
            ArtifactImportCoordinator.outputsDirectory,
            Self.taskAttachmentsDirectory,
            AppPaths.supersededClusterAttemptsDirectory,
        ]

        for directory in directories where fm.fileExists(atPath: directory.path) {
            try? fm.removeItem(at: directory)
        }
    }

    private func refreshTasks() {
        do {
            let descriptor = FetchDescriptor<TaskRecord>(
                sortBy: [
                    SortDescriptor(\.sortOrder, order: .forward),
                    SortDescriptor(\.createdAt, order: .reverse)
                ]
            )
            tasks = try modelContext.fetch(descriptor)
        } catch {
            tasks = []
        }

        let currentTasks = tasks
        let coordinator = artifactImportCoordinator
        let index = remoteTaskIndex
        let disp = dispatcher!
        let ctx = modelContext
        Task { [weak self] in
            guard self != nil else { return }
            await coordinator.importRecentCompleted(
                tasks: currentTasks,
                peerClient: { peer in await disp.peerClient(for: peer) },
                peerLookup: { id in await self?.clusterCoordinator?.peer(id: id) },
                remoteTaskIndex: index,
                saveContext: { try ctx.save() }
            )
        }

        syncLiveActivities()
        triggerCallsForStateTransitions()
    }

    // MARK: - Local Incoming Call Triggers

    private static let callTriggerStatuses: Set<TaskStatus> = [
        .planReview, .writebackReview, .completed, .failed, .timedOut, .maxIterations, .planFailed,
    ]

    private func triggerCallsForStateTransitions() {
        guard let incomingCallManager else { return }

        for task in tasks {
            let previous = previousStatuses[task.id]
            let current = task.status

            if previous != current {
                if previous == .planReview {
                    callTriggeredTaskIds.remove(task.id + ":\(TaskStatus.planReview.rawValue)")
                    incomingCallManager.clearHandledCall(taskId: task.id, trigger: .planReady)
                }
                if previous == .writebackReview {
                    callTriggeredTaskIds.remove(task.id + ":\(TaskStatus.writebackReview.rawValue)")
                    incomingCallManager.clearHandledCall(taskId: task.id, trigger: .writebackReady)
                }
            }

            guard previous != current,
                  Self.callTriggerStatuses.contains(current),
                  callTriggeredTaskIds.insert(task.id + ":\(current.rawValue)").inserted
            else { continue }

            let trigger: IncomingCallContext.TriggerEvent
            switch current {
            case .planReview:       trigger = .planReady
            case .writebackReview:  trigger = .writebackReady
            case .completed:        trigger = .completed
            case .failed, .timedOut, .maxIterations, .planFailed:
                                    trigger = .failed
            default: continue
            }

            if incomingCallManager.hasHandledCall(taskId: task.id, trigger: trigger) {
                continue
            }

            let summary: String
            switch trigger {
            case .planReady:
                summary = task.planMarkdown.flatMap { $0.isEmpty ? nil : "Plan: \($0.prefix(300))" }
                    ?? "Plan ready for: \(task.title)"
            case .writebackReady:
                let count = task.pendingWritebackOperations.count
                summary = "\(count) file\(count == 1 ? "" : "s") ready for review — \(task.title)"
            default:
                summary = task.resultSummary ?? task.title
            }

            let context = IncomingCallContext(
                trigger: trigger,
                taskId: task.id,
                workerName: task.title,
                summary: summary,
                peerId: task.clusterPeerId ?? ""
            )
            VoIPDiagnosticsLog.log("[HivelinkTaskService] Local state trigger: task=\(task.id) trigger=\(trigger.rawValue) status=\(current.rawValue)")
            incomingCallManager.offerCall(context: context)
        }

        previousStatuses = Dictionary(
            tasks.map { ($0.id, $0.status) },
            uniquingKeysWith: { _, latest in latest }
        )
        persistCallTriggeredIds()
    }

    private func persistCallTriggeredIds() {
        var array = Array(callTriggeredTaskIds)
        if array.count > 500 {
            array = Array(array.suffix(250))
            callTriggeredTaskIds = Set(array)
        }
        UserDefaults.standard.set(array, forKey: Self.callTriggeredIdsKey)
    }

    private func performPeerAction(
        _ task: TaskRecord,
        action: String,
        instructions: String? = nil
    ) async {
        guard let peerId = await remoteTaskIndex.peerId(for: task.id),
              let workerTaskId = await remoteTaskIndex.workerTaskId(for: task.id),
              let coordinator = clusterCoordinator,
              let peer = await coordinator.peer(id: peerId)
        else { return }

        let client = await dispatcher.peerClient(for: peer)
        _ = try? await client.performAction(
            taskId: workerTaskId,
            action: action,
            instructions: instructions
        )
    }

    private func convertToAPIStatus(_ status: TaskStatus) -> APITaskStatus {
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

    private func prepareRequestsForCreation(_ requests: [TaskCreationRequest]) async throws -> [TaskCreationRequest] {
        var prepared: [TaskCreationRequest] = []
        prepared.reserveCapacity(requests.count)

        for request in requests {
            let normalized = normalizedCreationRequest(request)

            if let continuationSourceTaskId = normalized.continuationSourceTaskId {
                guard let sourceTask = tasks.first(where: { $0.id == continuationSourceTaskId }) else {
                    throw TaskCreationPreparationError.missingContinuationSource(taskId: continuationSourceTaskId)
                }

                let imported = await ensureContinuationArtifactsAvailable(for: sourceTask)
                guard imported else {
                    throw TaskCreationPreparationError.failedToImportContinuationArtifacts(
                        taskTitle: sourceTask.title,
                        detail: artifactImportCoordinator.lastImportError
                    )
                }
            }

            prepared.append(normalized)
        }

        return prepared
    }

    private func normalizedCreationRequest(_ request: TaskCreationRequest) -> TaskCreationRequest {
        var referencedTaskIds = request.referencedTaskIds
        if let continuationSourceTaskId = request.continuationSourceTaskId,
           !referencedTaskIds.contains(continuationSourceTaskId) {
            referencedTaskIds.append(continuationSourceTaskId)
        }

        return TaskCreationRequest(
            taskId: request.taskId,
            description: request.description,
            providerId: request.providerId,
            modelId: request.modelId,
            executionTarget: request.executionTarget,
            runtimeTarget: request.runtimeTarget,
            reasoningEnabled: request.reasoningEnabled,
            reasoningEffort: request.reasoningEffort,
            serviceTier: request.serviceTier,
            attachedFilePaths: request.attachedFilePaths,
            attachmentInfos: request.attachmentInfos,
            outputDirectory: request.outputDirectory,
            mentionedSkillNames: request.mentionedSkillNames,
            referencedTaskIds: referencedTaskIds,
            continuationSourceTaskId: request.continuationSourceTaskId,
            retrievalContextPackId: request.retrievalContextPackId,
            retrievalInlineContextBlocks: request.retrievalInlineContextBlocks,
            retrievalContextAttachmentPaths: request.retrievalContextAttachmentPaths,
            retrievalSelectedSuggestionIds: request.retrievalSelectedSuggestionIds,
            retrievalModeOverrides: request.retrievalModeOverrides,
            clusterReferenceContextBlocks: request.clusterReferenceContextBlocks,
            clusterReferenceFiles: request.clusterReferenceFiles,
            planFirstEnabled: request.planFirstEnabled,
            planMarkdown: request.planMarkdown,
            planSelectedSkillNames: request.planSelectedSkillNames,
            localAccessGrants: request.localAccessGrants,
            clusterOwnerTaskId: request.clusterOwnerTaskId,
            clusterExecutionAttempt: request.clusterExecutionAttempt,
            clusterLeaseId: request.clusterLeaseId
        )
    }

    private func ensureContinuationArtifactsAvailable(for task: TaskRecord) async -> Bool {
        guard task.wasExecutedRemotely else {
            return true
        }

        if task.sessionId != nil {
            return true
        }

        let success = await artifactImportCoordinator.importOnDemand(
            task: task,
            peerClient: { peer in await self.dispatcher.peerClient(for: peer) },
            peerLookup: { id in await self.clusterCoordinator?.peer(id: id) },
            remoteTaskIndex: remoteTaskIndex,
            saveContext: { try self.modelContext.save() }
        )

        if success {
            refreshTasks()
        }

        return success
    }

    private func apiInputFiles(for task: TaskRecord) -> [APIFile] {
        task.attachedFilePaths.map { path in
            let url = URL(fileURLWithPath: path)
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
            return APIFile(
                name: url.lastPathComponent,
                size: size,
                mimeType: APIFile.mimeType(for: url.lastPathComponent)
            )
        }
    }

    private func apiOutputFiles(for task: TaskRecord) -> [APIFile] {
        guard let outputPaths = task.outputFilePaths else { return [] }
        return outputPaths.map { path in
            let url = URL(fileURLWithPath: path)
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
            return APIFile(
                name: url.lastPathComponent,
                size: size,
                mimeType: APIFile.mimeType(for: url.lastPathComponent)
            )
        }
    }

    private func resolvedDirectReferencedTasks(for task: TaskRecord) -> [TaskRecord] {
        let ids = task.referencedTaskIds ?? []
        var seen = Set<String>()
        return ids.compactMap { id in
            guard seen.insert(id).inserted else { return nil }
            return tasks.first(where: { $0.id == id })
        }
    }

    private func resolvedAncestorReferencedTasks(for task: TaskRecord) -> [TaskRecord] {
        var seen = Set<String>()
        var orderedAncestors: [TaskRecord] = []

        func visit(_ current: TaskRecord) {
            for referencedID in current.referencedTaskIds ?? [] {
                guard seen.insert(referencedID).inserted else { continue }
                guard let ancestor = tasks.first(where: { $0.id == referencedID }) else { continue }
                orderedAncestors.append(ancestor)
                visit(ancestor)
            }
        }

        visit(task)
        return orderedAncestors
    }

    private func taskReferenceContextMarkdown(
        for task: TaskRecord,
        ancestorTasks: [TaskRecord],
        guestBundlePath: String
    ) -> String {
        var sections: [String] = []
        sections.append("# \(task.title)")
        sections.append(
            """
            - Task ID: `\(task.id)`
            - Status: \(task.status.displayName)
            - Created: \(task.createdAt.formatted(date: .abbreviated, time: .shortened))
            - Bundle Path: `\(guestBundlePath)`
            """
        )
        sections.append(
            """
            ## Original Prompt
            \(task.taskDescription)
            """
        )

        let inlineBlocks = task.retrievalInlineContextBlocks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !inlineBlocks.isEmpty {
            let rendered = inlineBlocks.enumerated().map { index, block in
                "### Injected Prompt \(index + 1)\n\(block)"
            }.joined(separator: "\n\n")
            sections.append("## Injected Prompts\n\(rendered)")
        }

        if let resultSummary = task.resultSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !resultSummary.isEmpty {
            sections.append("## Result Summary\n\(resultSummary)")
        }

        if let traceSummary = sessionEndSummary(for: task)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !traceSummary.isEmpty,
           traceSummary != task.resultSummary?.trimmingCharacters(in: .whitespacesAndNewlines) {
            sections.append("## Session Trace Summary\n\(traceSummary)")
        }

        sections.append(
            """
            ## Materialized Files
            - Prior inbox snapshot: `\(guestBundlePath)/inbox/`
            - Prior outbox snapshot: `\(guestBundlePath)/outbox/`
            - Prior workspace snapshot: `\(guestBundlePath)/workspace/`
            """
        )

        if !ancestorTasks.isEmpty {
            let provenance = ancestorTasks.map { ancestor in
                var lines: [String] = []
                lines.append("### \(ancestor.title)")
                lines.append("- Task ID: `\(ancestor.id)`")
                lines.append("- Status: \(ancestor.status.displayName)")
                lines.append("- Prompt: \(ancestor.taskDescription)")
                if let summary = ancestor.resultSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
                    lines.append("- Result Summary: \(summary)")
                }
                if let traceSummary = sessionEndSummary(for: ancestor)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !traceSummary.isEmpty {
                    lines.append("- Trace Summary: \(traceSummary)")
                }
                return lines.joined(separator: "\n")
            }.joined(separator: "\n\n")
            sections.append("## Referenced Ancestors\n\(provenance)")
        }

        return sections.joined(separator: "\n\n")
    }

    private func sessionEndSummary(for task: TaskRecord) -> String? {
        guard let sessionId = task.sessionId else { return nil }
        let traceURL = AppPaths.sessionDirectory(id: sessionId).appendingPathComponent("trace.jsonl")
        guard let contents = try? String(contentsOf: traceURL, encoding: .utf8) else { return nil }

        for line in contents.components(separatedBy: .newlines).reversed() where !line.isEmpty {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String,
                  type == "session_end",
                  let eventData = json["data"] as? [String: Any],
                  let sessionEnd = eventData["sessionEnd"] as? [String: Any],
                  let inner = sessionEnd["_0"] as? [String: Any],
                  let summary = inner["summary"] as? String,
                  !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                continue
            }
            return summary
        }

        return nil
    }

    private func copyReferenceWorkspace(
        from sessionId: String?,
        to destinationDirectory: URL
    ) throws {
        guard let sessionId else { return }

        let sourceDirectory = AppPaths.sessionWorkspaceDirectory(id: sessionId)
        guard FileManager.default.fileExists(atPath: sourceDirectory.path) else { return }

        let fm = FileManager.default
        if fm.fileExists(atPath: destinationDirectory.path) {
            try fm.removeItem(at: destinationDirectory)
        }
        try fm.copyItem(at: sourceDirectory, to: destinationDirectory)
    }

    private func copyReferenceFiles(
        from paths: [String],
        to destinationDirectory: URL,
        copiedFileSources: inout [String: URL]
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        for path in paths {
            let sourceURL = URL(fileURLWithPath: path)
            guard fm.fileExists(atPath: sourceURL.path) else { continue }

            var destinationURL = destinationDirectory.appendingPathComponent(sourceURL.lastPathComponent)
            destinationURL = uniqueFileURL(for: destinationURL)
            try copyReferenceFile(
                from: sourceURL,
                to: destinationURL,
                copiedFileSources: &copiedFileSources
            )
        }
    }

    private func copyReferenceFile(
        from sourceURL: URL,
        to destinationURL: URL,
        copiedFileSources: inout [String: URL]
    ) throws {
        let fm = FileManager.default
        let canonicalSourcePath = sourceURL.resolvingSymlinksInPath().standardizedFileURL.path

        if let existingDestination = copiedFileSources[canonicalSourcePath],
           fm.fileExists(atPath: existingDestination.path) {
            do {
                try fm.linkItem(at: existingDestination, to: destinationURL)
                return
            } catch {
                // Fall back to a normal copy.
            }
        }

        try fm.copyItem(at: sourceURL, to: destinationURL)
        copiedFileSources[canonicalSourcePath] = destinationURL
    }

    private func uniqueFileURL(for url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }

        let baseName = url.deletingPathExtension().lastPathComponent
        let pathExtension = url.pathExtension
        let directory = url.deletingLastPathComponent()

        var counter = 2
        while true {
            let candidateName: String
            if pathExtension.isEmpty {
                candidateName = "\(baseName)-\(counter)"
            } else {
                candidateName = "\(baseName)-\(counter).\(pathExtension)"
            }

            let candidate = directory.appendingPathComponent(candidateName)
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
            counter += 1
        }
    }

    private func uniqueReferenceBundleName(for task: TaskRecord, usedNames: inout Set<String>) -> String {
        let rawSlug = task.title
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let slug = rawSlug.isEmpty ? "task" : String(rawSlug.prefix(40))
        let baseName = "\(slug)-\(task.id.prefix(8))"

        var candidate = baseName
        var counter = 2
        while usedNames.contains(candidate) {
            candidate = "\(baseName)-\(counter)"
            counter += 1
        }
        usedNames.insert(candidate)
        return candidate
    }

    private static func placeholderTitle(from description: String) -> String {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 50 else { return trimmed.isEmpty ? "Task" : trimmed }
        let endIndex = trimmed.index(trimmed.startIndex, offsetBy: 50)
        return String(trimmed[..<endIndex]) + "…"
    }

    private static var taskAttachmentsDirectory: URL {
        AppPaths.appSupportDirectory.appendingPathComponent(taskAttachmentsDirectoryName, isDirectory: true)
    }

    private func persistAttachmentsToDisk(for task: TaskRecord) {
        let infos = task.attachmentInfos
        guard !infos.isEmpty else { return }

        let fm = FileManager.default
        let attachmentsDir = Self.taskAttachmentsDirectory
            .appendingPathComponent(task.id, isDirectory: true)
        try? fm.createDirectory(at: attachmentsDir, withIntermediateDirectories: true)

        var updated: [AttachmentInfo] = []
        for info in infos {
            let sourcePath = info.effectivePath
            guard fm.fileExists(atPath: sourcePath) else {
                updated.append(info)
                continue
            }
            let destination = attachmentsDir.appendingPathComponent(
                URL(fileURLWithPath: sourcePath).lastPathComponent
            )
            do {
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
                try fm.copyItem(
                    at: URL(fileURLWithPath: sourcePath),
                    to: destination
                )
                updated.append(AttachmentInfo(
                    originalPath: info.originalPath,
                    copiedPath: destination.path,
                    fileSize: info.fileSize
                ))
            } catch {
                updated.append(info)
            }
        }
        task.attachmentInfos = updated
    }
}
