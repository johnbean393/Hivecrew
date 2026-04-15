//
//  HivelinkTaskService.swift
//  Hivelink
//
//  SwiftData-backed task list, remote dispatch host, and peer task actions.
//

import Combine
import Foundation
import HivecrewAPIModels
import HivecrewCore
import SwiftData
import UIKit

// MARK: - Task service

@MainActor
final class HivelinkTaskService: ObservableObject, TaskServiceProtocol, RemoteTaskDispatchHost {

    private let modelContext: ModelContext
    private(set) weak var clusterCoordinator: HivelinkClusterCoordinator?

    @Published private(set) var tasks: [TaskRecord] = []

    private(set) var remoteTaskIndex: RemoteTaskIndex
    private(set) var dispatcher: RemoteTaskDispatcher!

    let artifactImportCoordinator = ArtifactImportCoordinator()

    /// Real-time SSE + screenshot monitoring for active remote tasks (owned by `HivelinkAppCore`).
    weak var peerConnectionManager: PeerConnectionManager?

    /// Long-running reconciliation loop; cancelled in `stopReconciliation()` (cannot use `Timer` + `deinit` with `@MainActor` isolation).
    private var reconciliationTask: Task<Void, Never>?

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

    /// Runs one remote reconciliation pass and refreshes the local task list.
    func reconcileAndRefresh() async {
        await dispatcher.reconcileRemoteTasks()
        refreshTasks()
        await peerConnectionManager?.syncMonitoring(tasks: tasks)
    }

    private func startReconciliation() {
        reconciliationTask?.cancel()
        reconciliationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.dispatcher.reconcileRemoteTasks()
                await self.peerConnectionManager?.syncMonitoring(tasks: self.tasks)
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

        for (index, existing) in tasks.enumerated() {
            existing.sortOrder = index + requests.count
        }

        var created: [TaskRecord] = []
        created.reserveCapacity(requests.count)

        for (index, request) in requests.enumerated() {
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

            modelContext.insert(task)
            created.append(task)
        }

        try modelContext.save()
        refreshTasks()

        for task in created {
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
        _ = task
        _ = referencesRoot
        return []
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

    // MARK: - Private helpers

    private func loadTasks() {
        refreshTasks()
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

    private static func placeholderTitle(from description: String) -> String {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 50 else { return trimmed.isEmpty ? "Task" : trimmed }
        let endIndex = trimmed.index(trimmed.startIndex, offsetBy: 50)
        return String(trimmed[..<endIndex]) + "…"
    }
}
