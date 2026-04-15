//
//  RemoteTaskDispatcher.swift
//  HivecrewCore
//
//  Cross-platform remote task dispatch and reconciliation (owner ↔ peer worker).
//

import Foundation
import HivecrewAPIModels
import HivecrewShared

// MARK: - Peer & lease models

public enum RemoteClusterPeerStatus: String, Sendable, Codable {
    case online
    case offline
    case unreachable
}

/// Minimal peer description for `PeerAPIClient` and dispatch decisions (mirrors app `PeerNode`).
public struct RemoteClusterPeer: Identifiable, Sendable, Hashable {
    public let id: String
    public let subdomain: String
    public let name: String?
    public let tunnelUrl: String
    public var status: RemoteClusterPeerStatus

    public init(
        id: String,
        subdomain: String,
        name: String?,
        tunnelUrl: String,
        status: RemoteClusterPeerStatus
    ) {
        self.id = id
        self.subdomain = subdomain
        self.name = name
        self.tunnelUrl = tunnelUrl
        self.status = status
    }

    public var displayName: String {
        name ?? subdomain
    }
}

/// Persisted or index-backed lease for a canonical task executed on a peer.
public struct RemoteTaskLease: Sendable, Hashable {
    public let leaseId: String
    public let peerId: String
    public let workerTaskId: String

    public init(leaseId: String, peerId: String, workerTaskId: String) {
        self.leaseId = leaseId
        self.peerId = peerId
        self.workerTaskId = workerTaskId
    }
}

// MARK: - Environment

/// Cluster directory and slot reservation (implemented by the app’s `ClusterManager`).
public protocol RemoteClusterDirectory: Sendable {
    func peer(id: String) async -> RemoteClusterPeer?
    func reserveBestAvailablePeer(providerName: String, modelId: String, excluding: Set<String>) async -> RemoteClusterPeer?
    func reserveSpecificPeer(peerId: String, providerName: String, modelId: String) async -> RemoteClusterPeer?
    func releaseSlot(peerId: String) async
    func markPeerOnline(tunnelId: String) async
    /// Primary cluster bearer token if known (keychain fallback is applied by the dispatcher).
    func clusterToken() async -> String?
}

/// Owner-side persistence and bridging for canonical tasks (implemented by `APIServiceProviderBridge` / task service).
@MainActor
public protocol RemoteTaskDispatchHost: AnyObject {
    func allTasks() -> [TaskRecord]
    func taskRecord(id: String) -> TaskRecord?
    func getProviderName(for providerId: String) -> String
    func convertToAPITask(_ task: TaskRecord) -> APITask
    func convertFromAPIStatus(_ status: APITaskStatus) -> TaskStatus
    func saveModelContext() throws
    func notifyTaskListChanged()
    /// `nil` means “unknown” — remote dispatch is allowed (same as original `shouldDispatchRemotely`).
    func localAvailableSlotsForDispatchDecision() async -> Int?
    /// Human-readable name for this device (shown on execution nodes as the task owner).
    func ownerDisplayName() -> String?
    func materializeTaskReferences(for task: TaskRecord, referencesRoot: URL) throws -> [String]
    func importCompletedRemoteArtifacts(
        task: TaskRecord,
        peer: RemoteClusterPeer,
        workerTaskId: String,
        remoteTask: APITask,
        client: PeerAPIClient
    ) async -> Bool
}

// MARK: - Dispatcher

/// Coordinates remote execute-now dispatch, lease health, and polling reconciliation against `RemoteTaskIndex`.
///
/// This is a `@MainActor` type (not `actor`) so canonical `TaskRecord` / SwiftData and `RemoteTaskDispatchHost`
/// stay on the main thread; a separate `actor` façade would not be able to pass `TaskRecord` across isolation
/// without data-race errors under Swift 6.
@MainActor
public final class RemoteTaskDispatcher {
    public static let peerOfflineRecoveryGrace: TimeInterval = 30
    public static let remoteLeaseFailureThreshold = 3
    public static let dispatchGrace: TimeInterval = 15

    private weak var host: (any RemoteTaskDispatchHost)?
    private let clusterDirectory: RemoteClusterDirectory
    private let remoteTaskIndex: RemoteTaskIndex

    private var peerClients: [String: PeerAPIClient] = [:]

    public init(
        host: any RemoteTaskDispatchHost,
        clusterDirectory: RemoteClusterDirectory,
        remoteTaskIndex: RemoteTaskIndex
    ) {
        self.host = host
        self.clusterDirectory = clusterDirectory
        self.remoteTaskIndex = remoteTaskIndex
    }

    public func setHost(_ host: any RemoteTaskDispatchHost) {
        self.host = host
    }

    // MARK: - Bootstrap

    public func bootstrapRemoteReconciliation() async {
        await restorePersistedRemoteTasks()
        await reconcileRemoteTasks()
    }

    public func restorePersistedRemoteTasks() async {
        guard let host else { return }

        let tasks = host.allTasks().filter {
            !$0.isInternalClusterExecution && $0.hasRemoteLease
        }

        guard !tasks.isEmpty else { return }

        for task in tasks {
            guard let lease = persistedRemoteLease(for: task) else { continue }
            if task.clusterLeaseId == nil || task.clusterLeaseId?.isEmpty == true {
                task.clusterLeaseId = lease.leaseId
            }
            let cachedTask = host.convertToAPITask(task)
            await remoteTaskIndex.register(
                canonicalTaskId: task.id,
                peerId: lease.peerId,
                workerTaskId: lease.workerTaskId,
                task: cachedTask
            )
        }
    }

    // MARK: - Reconciliation

    public func reconcileRemoteTasks() async {
        guard let host else { return }

        let entries = await remoteTaskIndex.allEntries()

        for task in host.allTasks() where task.hasRemoteLease {
            guard !task.status.isTerminal else { continue }
            guard let lease = persistedRemoteLease(for: task) else { continue }
            guard let peer = await clusterDirectory.peer(id: lease.peerId) else {
                noteLeaseFailure(for: task, state: .suspect, reason: "Remote worker node is missing from the cluster directory.")
                if leaseFailureDuration(for: task) >= Self.peerOfflineRecoveryGrace {
                    await recoverLostLease(for: task, reason: "Remote lease owner could not find worker node. Task re-queued.")
                }
                continue
            }

            if peer.status != .online {
                noteLeaseFailure(for: task, state: .suspect, reason: "Worker is offline. Waiting briefly before recovering task.")
                if leaseFailureDuration(for: task) >= Self.peerOfflineRecoveryGrace {
                    await recoverLostLease(for: task, reason: "Worker remained offline. Task re-queued for recovery.")
                }
            }
        }

        guard !entries.isEmpty else {
            try? host.saveModelContext()
            host.notifyTaskListChanged()
            return
        }

        for entry in entries {
            guard let peer = await clusterDirectory.peer(id: entry.peerId), peer.status == .online else { continue }
            guard let task = host.taskRecord(id: entry.canonicalTaskId) else {
                continue
            }

            do {
                let client = await peerClient(for: peer)
                let remoteTask = try await client.getTask(id: entry.workerTaskId)
                await clusterDirectory.markPeerOnline(tunnelId: peer.id)
                let tagged = tagWithNode(remoteTask, peer: peer, canonicalTaskId: entry.canonicalTaskId)
                await remoteTaskIndex.update(canonicalTaskId: entry.canonicalTaskId, task: tagged)
                await applyRemoteExecutionSnapshot(
                    canonicalTaskId: entry.canonicalTaskId,
                    peer: peer,
                    workerTaskId: entry.workerTaskId,
                    remoteTask: remoteTask
                )
            } catch let error as PeerAPIError {
                let missingTask: Bool
                if case .httpError(let statusCode, _) = error {
                    missingTask = statusCode == 404
                } else {
                    missingTask = false
                }
                noteLeaseFailure(
                    for: task,
                    state: missingTask ? .recovering : .suspect,
                    reason: missingTask
                        ? "Remote worker task disappeared. Attempting lease recovery."
                        : "Remote worker check failed. Awaiting additional evidence before recovery."
                )
                if shouldRecoverLease(for: task, missingTask: missingTask) {
                    await recoverLostLease(
                        for: task,
                        reason: missingTask
                            ? "Remote worker task was lost. Task re-queued for recovery."
                            : "Remote worker could not be reached consistently. Task re-queued for recovery."
                    )
                }
            } catch {
                noteLeaseFailure(
                    for: task,
                    state: .suspect,
                    reason: "Remote worker check failed. Awaiting additional evidence before recovery."
                )
                if shouldRecoverLease(for: task) {
                    await recoverLostLease(for: task, reason: "Remote worker could not be reached consistently. Task re-queued for recovery.")
                }
            }
        }

        try? host.saveModelContext()
        host.notifyTaskListChanged()
    }

    public func recoverTasksForOfflinePeer(_ peerId: String) async {
        guard let host else { return }

        let affectedTasks = host.allTasks().filter {
            $0.clusterPeerId == peerId && $0.clusterExecutionState != .none
        }

        guard !affectedTasks.isEmpty else { return }

        for task in affectedTasks {
            noteLeaseFailure(for: task, state: .suspect, reason: "Worker became unreachable. Awaiting recovery window.")
        }

        try? host.saveModelContext()
        host.notifyTaskListChanged()
    }

    // MARK: - Lease resolution

    public func persistedRemoteLease(for task: TaskRecord) -> RemoteTaskLease? {
        guard let peerId = task.clusterPeerId, !peerId.isEmpty,
              let workerTaskId = task.clusterWorkerTaskId, !workerTaskId.isEmpty else {
            return nil
        }
        let leaseId = (task.clusterLeaseId?.isEmpty == false ? task.clusterLeaseId : workerTaskId) ?? workerTaskId
        return RemoteTaskLease(leaseId: leaseId, peerId: peerId, workerTaskId: workerTaskId)
    }

    public func resolveRemoteLease(canonicalTaskId: String) async -> RemoteTaskLease? {
        guard let host else { return nil }

        if let peerId = await remoteTaskIndex.peerId(for: canonicalTaskId),
           let workerTaskId = await remoteTaskIndex.workerTaskId(for: canonicalTaskId),
           let task = host.taskRecord(id: canonicalTaskId) {
            let leaseId = (task.clusterLeaseId?.isEmpty == false ? task.clusterLeaseId : workerTaskId) ?? workerTaskId
            return RemoteTaskLease(leaseId: leaseId, peerId: peerId, workerTaskId: workerTaskId)
        }

        guard let task = host.taskRecord(id: canonicalTaskId),
              let lease = persistedRemoteLease(for: task) else {
            return nil
        }

        await remoteTaskIndex.register(
            canonicalTaskId: canonicalTaskId,
            peerId: lease.peerId,
            workerTaskId: lease.workerTaskId,
            task: host.convertToAPITask(task)
        )
        return lease
    }

    public func makeLeaseId(canonicalTaskId: String, executionAttempt: Int, ownerTunnelId: String) -> String {
        "\(canonicalTaskId)::\(executionAttempt)::\(ownerTunnelId)"
    }

    // MARK: - Dispatch

    /// Dispatches a queued canonical task to an available peer. Returns `false` if no remote dispatch occurred.
    public func dispatchQueuedCanonicalTaskToPeer(_ task: TaskRecord) async -> Bool {
        guard let host else { return false }

        guard task.status == .queued, task.clusterExecutionState == .none else { return false }
        guard !task.isPinnedToLocalExecution else { return false }

        let localAvailableSlots = await host.localAvailableSlotsForDispatchDecision()
        if task.executionTarget.kind == .automatic,
           !Self.shouldDispatchRemotely(
                requiresRemoteClusterExecution: task.requiresRemoteClusterExecution,
                localAvailableSlots: localAvailableSlots
           ) {
            return false
        }

        let providerName = host.getProviderName(for: task.providerId)
        guard providerName != "Unknown" else { return false }
        guard let ownerTunnelId = RemoteAccessKeychain.retrieveTunnelId(), !ownerTunnelId.isEmpty else {
            return false
        }

        var executionAttempt: Int?
        var triedPeerIds: Set<String> = []

        func nextPeer() async -> RemoteClusterPeer? {
            switch task.executionTarget.kind {
            case .automatic, .remoteFirst:
                return await clusterDirectory.reserveBestAvailablePeer(
                    providerName: providerName,
                    modelId: task.modelId,
                    excluding: triedPeerIds
                )
            case .local:
                return nil
            case .peer:
                guard let peerId = task.executionTarget.targetPeerId,
                      !triedPeerIds.contains(peerId) else {
                    return nil
                }
                return await clusterDirectory.reserveSpecificPeer(
                    peerId: peerId,
                    providerName: providerName,
                    modelId: task.modelId
                )
            }
        }

        while let peer = await nextPeer() {
            triedPeerIds.insert(peer.id)

            if executionAttempt == nil {
                task.clusterExecutionState = .dispatchingRemote
                task.clusterExecutionAttempt += 1
                let leaseId = makeLeaseId(
                    canonicalTaskId: task.id,
                    executionAttempt: task.clusterExecutionAttempt,
                    ownerTunnelId: ownerTunnelId
                )
                task.clusterLeaseId = leaseId
                task.clusterWorkerTaskId = leaseId
                task.clusterPeerId = peer.id
                task.clusterPeerName = peer.name ?? peer.subdomain
                task.remoteLeaseState = .dispatching
                task.clusterLeaseFailureCount = 0
                task.clusterLeaseFirstFailureAt = nil
                task.clusterLastRemoteContactAt = nil
                try? host.saveModelContext()
                host.notifyTaskListChanged()
                executionAttempt = task.clusterExecutionAttempt
            }

            do {
                let client = await peerClient(for: peer)
                let stagedInputs = try await stageInputs(for: task, on: peer, using: client)
                let stagedReferences = try await stageTaskReferenceArtifacts(for: task, on: peer, using: client)
                let response = try await client.executeNow(
                    ClusterExecuteNowRequest(
                        canonicalTaskId: task.id,
                        ownerTunnelId: ownerTunnelId,
                        ownerName: host.ownerDisplayName(),
                        ownerLeaseId: task.clusterLeaseId ?? makeLeaseId(
                            canonicalTaskId: task.id,
                            executionAttempt: executionAttempt ?? task.clusterExecutionAttempt,
                            ownerTunnelId: ownerTunnelId
                        ),
                        executionAttempt: executionAttempt ?? task.clusterExecutionAttempt,
                        description: task.taskDescription,
                        providerName: providerName,
                        modelId: task.modelId,
                        reasoningEnabled: task.reasoningEnabled,
                        reasoningEffort: task.reasoningEffort,
                        attachedFilePaths: stagedInputs.attached,
                        outputDirectory: nil,
                        planFirst: task.planFirstEnabled,
                        planMarkdown: task.planMarkdown,
                        mentionedSkillNames: task.mentionedSkillNames ?? [],
                        referencedTaskIds: task.referencedTaskIds ?? [],
                        continuationSourceTaskId: task.continuationSourceTaskId,
                        contextPackId: task.retrievalContextPackId,
                        contextSuggestionIds: task.retrievalSelectedSuggestionIds ?? [],
                        contextModeOverrides: task.retrievalModeOverrides,
                        contextInlineBlocks: task.retrievalInlineContextBlocks,
                        contextAttachmentPaths: stagedInputs.contextAttachments,
                        referenceContextBlocks: stagedReferences.contextBlocks,
                        referenceFiles: stagedReferences.files
                    )
                )

                let taggedTask = tagWithNode(response.task, peer: peer, canonicalTaskId: task.id)
                await remoteTaskIndex.register(
                    canonicalTaskId: task.id,
                    peerId: peer.id,
                    workerTaskId: response.workerTaskId,
                    task: taggedTask
                )
                await applyRemoteExecutionSnapshot(
                    canonicalTaskId: task.id,
                    peer: peer,
                    workerTaskId: response.workerTaskId,
                    remoteTask: response.task
                )

                return true
            } catch {
                await clusterDirectory.releaseSlot(peerId: peer.id)
                if case PeerAPIError.httpError(let statusCode, _) = error, statusCode == 409 {
                    task.clusterPeerId = nil
                    task.clusterPeerName = nil
                } else {
                    noteLeaseFailure(
                        for: task,
                        state: .suspect,
                        reason: "Remote dispatch response was interrupted. Reconciling remote lease before retry."
                    )
                    await remoteTaskIndex.register(
                        canonicalTaskId: task.id,
                        peerId: peer.id,
                        workerTaskId: task.clusterWorkerTaskId ?? task.clusterLeaseId ?? peer.id,
                        task: host.convertToAPITask(task)
                    )
                    try? host.saveModelContext()
                    host.notifyTaskListChanged()
                    return true
                }
            }
        }

        if executionAttempt != nil {
            task.clusterExecutionState = .none
            clearRemoteLease(for: task)
            try? host.saveModelContext()
            host.notifyTaskListChanged()
        }
        return false
    }

    /// Applies a fresh `APITask` snapshot from the worker to the canonical `TaskRecord` (and imports artifacts when terminal).
    public func applyRemoteExecutionSnapshot(
        canonicalTaskId: String,
        peer: RemoteClusterPeer,
        workerTaskId: String,
        remoteTask: APITask
    ) async {
        guard let host else { return }
        guard let task = host.taskRecord(id: canonicalTaskId) else { return }

        task.clusterLeaseId = task.clusterLeaseId ?? workerTaskId
        task.clusterWorkerTaskId = workerTaskId
        task.clusterPeerId = peer.id
        task.clusterPeerName = peer.name ?? peer.subdomain
        task.startedAt = remoteTask.startedAt ?? task.startedAt
        task.completedAt = remoteTask.completedAt
        task.resultSummary = remoteTask.resultSummary
        task.errorMessage = remoteTask.errorMessage
        task.wasSuccessful = remoteTask.wasSuccessful
        if let plan = remoteTask.planMarkdown, !plan.isEmpty {
            task.planMarkdown = plan
        }
        task.status = host.convertFromAPIStatus(remoteTask.status)
        resetLeaseHealth(
            for: task,
            state: remoteTask.status.isTerminal ? .completedAwaitingImport : .running
        )

        switch remoteTask.status {
        case .completed, .failed, .cancelled, .timedOut, .maxIterations, .planFailed, .writebackReview:
            let client = await peerClient(for: peer)
            let imported = await host.importCompletedRemoteArtifacts(
                task: task,
                peer: peer,
                workerTaskId: workerTaskId,
                remoteTask: remoteTask,
                client: client
            )
            task.clusterExecutionState = .none
            if imported {
                // Clear lease tracking but preserve peer/worker IDs so on-demand
                // import can retry if the trace files are later lost.
                task.clusterLeaseId = nil
                task.clusterLastRemoteContactAt = nil
                task.clusterLeaseFirstFailureAt = nil
                task.clusterLeaseFailureCount = 0
                task.remoteLeaseState = .none
                await remoteTaskIndex.remove(canonicalTaskId: canonicalTaskId)
            }
        default:
            task.clusterExecutionState = .runningRemote
        }

        try? host.saveModelContext()
        host.notifyTaskListChanged()
    }

    public func tagWithNode(_ task: APITask, peer: RemoteClusterPeer, canonicalTaskId: String) -> APITask {
        APITask(
            id: canonicalTaskId, title: task.title, description: task.description,
            status: task.status, providerName: task.providerName, modelId: task.modelId,
            reasoningEnabled: task.reasoningEnabled, reasoningEffort: task.reasoningEffort,
            createdAt: task.createdAt, startedAt: task.startedAt, completedAt: task.completedAt,
            resultSummary: task.resultSummary, errorMessage: task.errorMessage,
            inputFiles: task.inputFiles, outputFiles: task.outputFiles,
            wasSuccessful: task.wasSuccessful, vmId: task.vmId,
            referencedTaskIds: task.referencedTaskIds,
            continuationSourceTaskId: task.continuationSourceTaskId,
            duration: task.duration, stepCount: task.stepCount, tokenUsage: task.tokenUsage,
            planMarkdown: task.planMarkdown, planFirst: task.planFirst,
            contextPackId: task.contextPackId, contextItemCount: task.contextItemCount,
            contextAttachmentCount: task.contextAttachmentCount,
            pendingQuestion: task.pendingQuestion, pendingPermission: task.pendingPermission,
            pendingWriteback: task.pendingWriteback, pendingWritebackCount: task.pendingWritebackCount,
            appliedWritebackPaths: task.appliedWritebackPaths,
            nodeId: peer.id, nodeName: peer.name ?? peer.subdomain
        )
    }

    // MARK: - Lease helpers

    public func resetLeaseHealth(for task: TaskRecord, state: RemoteLeaseState) {
        task.remoteLeaseState = state
        task.clusterLeaseFailureCount = 0
        task.clusterLeaseFirstFailureAt = nil
        task.clusterLastRemoteContactAt = Date()
        if state != .completedAwaitingImport {
            task.errorMessage = nil
        }
    }

    public func noteLeaseFailure(for task: TaskRecord, state: RemoteLeaseState, reason: String) {
        task.clusterLeaseFailureCount += 1
        if task.clusterLeaseFirstFailureAt == nil {
            task.clusterLeaseFirstFailureAt = Date()
        }
        task.remoteLeaseState = state
        task.clusterExecutionState = .recoveringRemote
        task.errorMessage = reason
    }

    public func leaseFailureDuration(for task: TaskRecord, now: Date = Date()) -> TimeInterval {
        guard let firstFailure = task.clusterLeaseFirstFailureAt else { return 0 }
        return now.timeIntervalSince(firstFailure)
    }

    public func shouldRecoverLease(for task: TaskRecord, missingTask: Bool = false) -> Bool {
        if missingTask {
            return task.clusterLeaseFailureCount >= 2 || leaseFailureDuration(for: task) >= 5
        }
        if task.remoteLeaseState == .dispatching {
            return leaseFailureDuration(for: task) >= Self.dispatchGrace
        }
        return task.clusterLeaseFailureCount >= Self.remoteLeaseFailureThreshold ||
            leaseFailureDuration(for: task) >= Self.peerOfflineRecoveryGrace
    }

    public func clearRemoteLease(for task: TaskRecord, preservePeerName: Bool = false) {
        task.clusterLeaseId = nil
        task.clusterWorkerTaskId = nil
        task.clusterPeerId = nil
        task.clusterExecutionState = .none
        if !preservePeerName {
            task.clusterPeerName = nil
        }
        task.clusterLastRemoteContactAt = nil
        task.clusterLeaseFirstFailureAt = nil
        task.clusterLeaseFailureCount = 0
        task.remoteLeaseState = .none
    }

    public func recoverLostLease(for task: TaskRecord, reason: String) async {
        guard let host else { return }

        task.clusterExecutionAttempt += 1
        task.clusterExecutionState = .none
        task.status = .queued
        task.completedAt = nil
        task.resultSummary = nil
        task.errorMessage = reason
        clearRemoteLease(for: task)
        await remoteTaskIndex.remove(canonicalTaskId: task.id)

        try? host.saveModelContext()
        host.notifyTaskListChanged()
    }

    public nonisolated static func shouldDispatchRemotely(
        requiresRemoteClusterExecution: Bool,
        localAvailableSlots: Int?
    ) -> Bool {
        if requiresRemoteClusterExecution {
            return true
        }
        guard let localAvailableSlots else {
            return true
        }
        return localAvailableSlots <= 0
    }

    // MARK: - Peer clients

    public func peerClient(for peer: RemoteClusterPeer) async -> PeerAPIClient {
        if let existing = peerClients[peer.id] { return existing }
        let token = await resolvedClusterToken()
        let client = PeerAPIClient(baseURL: peer.tunnelUrl, clusterToken: token)
        peerClients[peer.id] = client
        return client
    }

    public func invalidatePeerClientCache() {
        peerClients.removeAll()
    }

    private func resolvedClusterToken() async -> String {
        if let token = await clusterDirectory.clusterToken(), !token.isEmpty {
            return token
        }
        return RemoteAccessKeychain.retrieveClusterToken() ?? ""
    }

    // MARK: - Staging

    private struct StagedTaskReferenceArtifacts {
        let contextBlocks: [String]
        let files: [ClusterExecuteNowRequest.ReferenceFile]
    }

    private func stageInputs(
        for task: TaskRecord,
        on peer: RemoteClusterPeer,
        using client: PeerAPIClient
    ) async throws -> (attached: [String], contextAttachments: [String]) {
        _ = peer
        let uniquePaths = Array(Set(task.attachedFilePaths + (task.retrievalContextAttachmentPaths ?? []))).sorted()
        guard !uniquePaths.isEmpty else {
            return (task.attachedFilePaths, task.retrievalContextAttachmentPaths ?? [])
        }

        let stagingId = "\(task.id)-attempt-\(task.clusterExecutionAttempt)"
        let stagedPaths = try await client.stageInputFiles(stagingId: stagingId, filePaths: uniquePaths)
        let mapping = Dictionary(uniqueKeysWithValues: zip(uniquePaths, stagedPaths))

        let attached = task.attachedFilePaths.compactMap { mapping[$0] }
        let contextAttachments = (task.retrievalContextAttachmentPaths ?? []).compactMap { mapping[$0] }
        return (attached, contextAttachments)
    }

    private func stageTaskReferenceArtifacts(
        for task: TaskRecord,
        on peer: RemoteClusterPeer,
        using client: PeerAPIClient
    ) async throws -> StagedTaskReferenceArtifacts {
        guard let host else {
            return StagedTaskReferenceArtifacts(contextBlocks: [], files: [])
        }

        _ = peer
        guard !(task.referencedTaskIds ?? []).isEmpty else {
            return StagedTaskReferenceArtifacts(contextBlocks: [], files: [])
        }

        let fm = FileManager.default
        let stagingRoot = AppPaths.appSupportDirectory
            .appendingPathComponent("ClusterReferenceStaging", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let referencesRoot = stagingRoot.appendingPathComponent("references", isDirectory: true)

        try fm.createDirectory(at: referencesRoot, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: stagingRoot)
        }

        let contextBlocks = try host.materializeTaskReferences(for: task, referencesRoot: referencesRoot)

        let files = collectRegularFiles(in: referencesRoot)
        guard !files.isEmpty else {
            return StagedTaskReferenceArtifacts(contextBlocks: contextBlocks, files: [])
        }

        let uploads = files.map { fileURL in
            let uniqueName = "\(UUID().uuidString)-\(fileURL.lastPathComponent)"
            return PeerAPIClient.StagedLocalFileUpload(
                localPath: fileURL.path,
                uploadFilename: uniqueName
            )
        }
        let stagedPaths = try await client.stageInputFiles(
            stagingId: "\(task.id)-attempt-\(task.clusterExecutionAttempt)-references",
            uploads: uploads
        )
        let referenceFiles = zip(files, stagedPaths).map { fileURL, stagedPath in
            let relativePath = fileURL.path.replacingOccurrences(
                of: referencesRoot.path + "/",
                with: ""
            )
            return ClusterExecuteNowRequest.ReferenceFile(
                relativePath: relativePath,
                stagedPath: stagedPath
            )
        }
        return StagedTaskReferenceArtifacts(contextBlocks: contextBlocks, files: referenceFiles)
    }

    private func collectRegularFiles(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            let isRegularFile = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            if isRegularFile {
                files.append(fileURL)
            }
        }
        return files.sorted { $0.path < $1.path }
    }
}

// MARK: - APITaskStatus

private extension APITaskStatus {
    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .timedOut, .maxIterations, .planFailed, .writebackReview:
            return true
        case .queued, .waitingForVM, .running, .paused, .planning, .planReview:
            return false
        }
    }
}
