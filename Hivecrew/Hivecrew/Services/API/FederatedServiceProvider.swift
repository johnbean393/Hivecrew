//
//  FederatedServiceProvider.swift
//  Hivecrew
//
//  APIServiceProvider that wraps the local bridge and adds remote dispatch/aggregation
//  when this machine is the cluster coordinator.
//

import Foundation
import Combine
import SwiftData
import HivecrewAPI

@MainActor
final class FederatedServiceProvider: APIServiceProvider, Sendable {
    
    private let localProvider: APIServiceProviderBridge
    private let clusterManager: ClusterManager
    private let remoteTaskIndex: RemoteTaskIndex
    
    /// Per-peer API client cache
    private var peerClients: [String: PeerAPIClient] = [:]
    
    private var drainObserver: NSObjectProtocol?
    private var peerUnavailableObserver: NSObjectProtocol?
    
    /// Begin listening for peer-available notifications to drain local queues.
    func startDrainObserver() {
        drainObserver = NotificationCenter.default.addObserver(
            forName: .clusterPeerBecameAvailable,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.drainQueuedTasksToPeers()
            }
        }
        
        peerUnavailableObserver = NotificationCenter.default.addObserver(
            forName: .clusterPeerBecameUnavailable,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let peerId = notification.object as? String else { return }
            Task { @MainActor in
                await self.recoverTasksForOfflinePeer(peerId)
            }
        }
    }
    
    /// Move locally queued tasks to peers that just became available.
    private func drainQueuedTasksToPeers() async {
        guard let taskService = APIServerManager.shared.taskServiceRef else { return }
        
        let queuedTasks = taskService.tasks
            .filter { $0.status == .queued && $0.clusterExecutionState == .none }
            .sorted { $0.createdAt < $1.createdAt }
        
        guard !queuedTasks.isEmpty else { return }
        
        for task in queuedTasks {
            guard task.status == .queued else { continue }
            _ = await dispatchQueuedCanonicalTaskToPeer(task)
        }
    }
    
    private func recoverTasksForOfflinePeer(_ peerId: String) async {
        let affectedTasks = localProvider.taskService.tasks.filter {
            $0.clusterPeerId == peerId && $0.clusterExecutionState != .none
        }
        
        guard !affectedTasks.isEmpty else { return }
        
        for task in affectedTasks {
            task.clusterExecutionAttempt += 1
            task.clusterExecutionState = .none
            task.clusterWorkerTaskId = nil
            task.clusterPeerId = nil
            task.clusterPeerName = nil
            task.status = .queued
            task.completedAt = nil
            task.resultSummary = nil
            task.errorMessage = "Worker went offline. Task re-queued for recovery."
            await remoteTaskIndex.remove(canonicalTaskId: task.id)
        }
        
        try? localProvider.modelContext.save()
        localProvider.taskService.objectWillChange.send()
        await drainQueuedTasksToPeers()
    }
    
    init(
        localProvider: APIServiceProviderBridge,
        clusterManager: ClusterManager,
        remoteTaskIndex: RemoteTaskIndex
    ) {
        self.localProvider = localProvider
        self.clusterManager = clusterManager
        self.remoteTaskIndex = remoteTaskIndex
    }
    
    // MARK: - Task Operations (federated)
    
    func createTask(
        description: String,
        providerName: String,
        modelId: String,
        reasoningEnabled: Bool?,
        reasoningEffort: String?,
        attachedFilePaths: [String],
        outputDirectory: String?,
        planFirst: Bool,
        mentionedSkillNames: [String],
        referencedTaskIds: [String],
        continuationSourceTaskId: String?,
        contextPackId: String?,
        contextSuggestionIds: [String],
        contextModeOverrides: [String: String],
        contextInlineBlocks: [String],
        contextAttachmentPaths: [String]
    ) async throws -> APITask {
        let localHasProvider = (try? await localProvider.getProviderByName(name: providerName)) != nil
        
        let canonicalTask = try await localProvider.createCanonicalClusterTask(
            description: description,
            providerName: providerName,
            modelId: modelId,
            reasoningEnabled: reasoningEnabled,
            reasoningEffort: reasoningEffort,
            attachedFilePaths: attachedFilePaths,
            outputDirectory: outputDirectory,
            planFirst: planFirst,
            mentionedSkillNames: mentionedSkillNames,
            referencedTaskIds: referencedTaskIds,
            continuationSourceTaskId: continuationSourceTaskId,
            contextPackId: contextPackId,
            contextSuggestionIds: contextSuggestionIds,
            contextModeOverrides: contextModeOverrides,
            contextInlineBlocks: contextInlineBlocks,
            contextAttachmentPaths: contextAttachmentPaths,
            autoStart: localHasProvider || planFirst
        )
        
        if canonicalTask.status == .queued && canonicalTask.clusterExecutionState == .none {
            _ = await dispatchQueuedCanonicalTaskToPeer(canonicalTask)
        }
        
        return try await getTask(id: canonicalTask.id)
    }
    
    func createTaskBatch(
        description: String,
        targets: [CreateTaskBatchTarget],
        attachedFilePaths: [String],
        planFirst: Bool,
        mentionedSkillNames: [String]
    ) async throws -> [APITask] {
        var createdTasks: [APITask] = []
        createdTasks.reserveCapacity(targets.count)
        
        for target in targets {
            let provider = try await getProvider(id: target.providerId)
            let task = try await createTask(
                description: description,
                providerName: provider.displayName,
                modelId: target.modelId,
                reasoningEnabled: target.reasoningEnabled,
                reasoningEffort: target.reasoningEffort,
                attachedFilePaths: attachedFilePaths,
                outputDirectory: nil,
                planFirst: planFirst,
                mentionedSkillNames: mentionedSkillNames,
                referencedTaskIds: [],
                continuationSourceTaskId: nil,
                contextPackId: nil,
                contextSuggestionIds: [],
                contextModeOverrides: [:],
                contextInlineBlocks: [],
                contextAttachmentPaths: []
            )
            createdTasks.append(task)
        }
        
        return createdTasks
    }
    
    func getTasks(
        status: [APITaskStatus]?,
        limit: Int,
        offset: Int,
        sortBy: String,
        order: String
    ) async throws -> APITaskListResponse {
        try await localProvider.getTasks(status: status, limit: limit, offset: offset, sortBy: sortBy, order: order)
    }
    
    func getTask(id: String) async throws -> APITask {
        if let peerId = await remoteTaskIndex.peerId(for: id),
           let workerTaskId = await remoteTaskIndex.workerTaskId(for: id) {
            let peers = await clusterManager.allOnlinePeers()
            guard let peer = peers.first(where: { $0.id == peerId }) else {
                // Peer is offline, return cached version
                if let cached = await remoteTaskIndex.cachedTask(for: id) {
                    return cached
                }
                return try await localProvider.getTask(id: id)
            }
            
            do {
                let client = await getOrCreateClient(for: peer)
                let task = try await client.getTask(id: workerTaskId)
                let tagged = tagWithNode(task, peer: peer, canonicalTaskId: id)
                await remoteTaskIndex.update(canonicalTaskId: id, task: tagged)
                await applyRemoteExecutionSnapshot(
                    canonicalTaskId: id,
                    peer: peer,
                    workerTaskId: workerTaskId,
                    remoteTask: task
                )
                return tagged
            } catch {
                if let cached = await remoteTaskIndex.cachedTask(for: id) {
                    return cached
                }
                return try await localProvider.getTask(id: id)
            }
        }
        return try await localProvider.getTask(id: id)
    }
    
    func performTaskAction(id: String, action: APITaskAction, instructions: String?) async throws -> APITask {
        if let peerId = await remoteTaskIndex.peerId(for: id),
           let workerTaskId = await remoteTaskIndex.workerTaskId(for: id) {
            let peers = await clusterManager.allOnlinePeers()
            guard let peer = peers.first(where: { $0.id == peerId }) else {
                throw APIError.notFound("Task not found (peer offline)")
            }
            let client = await getOrCreateClient(for: peer)
            let task = try await client.performAction(taskId: workerTaskId, action: action.rawValue, instructions: instructions)
            let tagged = tagWithNode(task, peer: peer, canonicalTaskId: id)
            await remoteTaskIndex.update(canonicalTaskId: id, task: tagged)
            await applyRemoteExecutionSnapshot(canonicalTaskId: id, peer: peer, workerTaskId: workerTaskId, remoteTask: task)
            return tagged
        }
        return try await localProvider.performTaskAction(id: id, action: action, instructions: instructions)
    }
    
    func deleteTask(id: String) async throws {
        if await remoteTaskIndex.peerId(for: id) != nil {
            await remoteTaskIndex.remove(canonicalTaskId: id)
        }
        try await localProvider.deleteTask(id: id)
    }
    
    func getTaskFiles(id: String) async throws -> APITaskFilesResponse {
        // Files are local to the machine that ran the task
        if await remoteTaskIndex.peerId(for: id) != nil {
            return APITaskFilesResponse(taskId: id, inputFiles: [], outputFiles: [])
        }
        return try await localProvider.getTaskFiles(id: id)
    }
    
    func getTaskFileData(taskId: String, filename: String, isInput: Bool) async throws -> (data: Data, mimeType: String) {
        return try await localProvider.getTaskFileData(taskId: taskId, filename: filename, isInput: isInput)
    }
    
    func getTaskScreenshot(id: String) async throws -> (data: Data, mimeType: String)? {
        if let peerId = await remoteTaskIndex.peerId(for: id),
           let workerTaskId = await remoteTaskIndex.workerTaskId(for: id) {
            let peers = await clusterManager.allOnlinePeers()
            guard let peer = peers.first(where: { $0.id == peerId }) else { return nil }
            let client = await getOrCreateClient(for: peer)
            return try await client.getScreenshot(taskId: workerTaskId)
        }
        return try await localProvider.getTaskScreenshot(id: id)
    }
    
    func getPendingQuestion(taskId: String) async throws -> APIAgentQuestion? {
        if await remoteTaskIndex.peerId(for: taskId) != nil {
            return await remoteTaskIndex.cachedTask(for: taskId)?.pendingQuestion
        }
        return try await localProvider.getPendingQuestion(taskId: taskId)
    }
    
    func answerQuestion(taskId: String, questionId: String, answer: String) async throws {
        if let peerId = await remoteTaskIndex.peerId(for: taskId),
           let workerTaskId = await remoteTaskIndex.workerTaskId(for: taskId) {
            let peers = await clusterManager.allOnlinePeers()
            guard let peer = peers.first(where: { $0.id == peerId }) else {
                throw APIError.notFound("Peer offline")
            }
            let client = await getOrCreateClient(for: peer)
            try await client.answerQuestion(taskId: workerTaskId, questionId: questionId, answer: answer)
            return
        }
        try await localProvider.answerQuestion(taskId: taskId, questionId: questionId, answer: answer)
    }
    
    func getPendingPermission(taskId: String) async throws -> APIPermissionRequest? {
        if await remoteTaskIndex.peerId(for: taskId) != nil {
            return await remoteTaskIndex.cachedTask(for: taskId)?.pendingPermission
        }
        return try await localProvider.getPendingPermission(taskId: taskId)
    }
    
    func respondToPermission(taskId: String, permissionId: String, approved: Bool) async throws {
        if let peerId = await remoteTaskIndex.peerId(for: taskId),
           let workerTaskId = await remoteTaskIndex.workerTaskId(for: taskId) {
            let peers = await clusterManager.allOnlinePeers()
            guard let peer = peers.first(where: { $0.id == peerId }) else {
                throw APIError.notFound("Peer offline")
            }
            let client = await getOrCreateClient(for: peer)
            try await client.respondToPermission(taskId: workerTaskId, permissionId: permissionId, approved: approved)
            return
        }
        try await localProvider.respondToPermission(taskId: taskId, permissionId: permissionId, approved: approved)
    }
    
    func getTaskWritebackReview(id: String) async throws -> APIWritebackReview? {
        // Writeback is local-only
        if await remoteTaskIndex.peerId(for: id) != nil { return nil }
        return try await localProvider.getTaskWritebackReview(id: id)
    }
    
    // MARK: - Schedule Operations (local only)
    
    func getScheduledTasks(limit: Int, offset: Int) async throws -> APIScheduledTaskListResponse {
        try await localProvider.getScheduledTasks(limit: limit, offset: offset)
    }
    
    func getScheduledTask(id: String) async throws -> APIScheduledTask {
        try await localProvider.getScheduledTask(id: id)
    }
    
    func createScheduledTask(
        title: String, description: String, providerName: String, modelId: String,
        reasoningEnabled: Bool?, reasoningEffort: String?,
        attachedFilePaths: [String], outputDirectory: String?, schedule: APISchedule
    ) async throws -> APIScheduledTask {
        try await localProvider.createScheduledTask(
            title: title, description: description, providerName: providerName, modelId: modelId,
            reasoningEnabled: reasoningEnabled, reasoningEffort: reasoningEffort,
            attachedFilePaths: attachedFilePaths, outputDirectory: outputDirectory, schedule: schedule
        )
    }
    
    func updateScheduledTask(id: String, request: UpdateScheduleRequest) async throws -> APIScheduledTask {
        try await localProvider.updateScheduledTask(id: id, request: request)
    }
    
    func deleteScheduledTask(id: String) async throws {
        try await localProvider.deleteScheduledTask(id: id)
    }
    
    func runScheduledTaskNow(id: String) async throws -> APITask {
        try await localProvider.runScheduledTaskNow(id: id)
    }
    
    // MARK: - Provider Operations (aggregated across cluster)
    
    private static let remoteProviderPrefix = "cluster-remote:"
    
    func getProviders() async throws -> APIProviderListResponse {
        let local = try await localProvider.getProviders()
        let localNames = Set(local.providers.map { $0.displayName.lowercased() })
        
        let onlinePeers = await clusterManager.allOnlinePeers()
        var remoteOnlyProviders: [APIProviderSummary] = []
        var seenRemoteNames: Set<String> = []
        
        for peer in onlinePeers {
            for prov in peer.providers {
                let key = prov.providerName.lowercased()
                guard !localNames.contains(key), !seenRemoteNames.contains(key) else { continue }
                seenRemoteNames.insert(key)
                remoteOnlyProviders.append(APIProviderSummary(
                    id: "\(Self.remoteProviderPrefix)\(prov.providerName)",
                    displayName: prov.providerName,
                    baseURL: "",
                    isDefault: false,
                    hasAPIKey: true,
                    createdAt: Date()
                ))
            }
        }
        
        return APIProviderListResponse(providers: local.providers + remoteOnlyProviders)
    }
    
    func getProvider(id: String) async throws -> APIProvider {
        if id.hasPrefix(Self.remoteProviderPrefix) {
            let name = String(id.dropFirst(Self.remoteProviderPrefix.count))
            return APIProvider(
                id: id,
                displayName: name,
                baseURL: "",
                isDefault: false,
                hasAPIKey: true,
                timeoutInterval: 120,
                createdAt: Date()
            )
        }
        return try await localProvider.getProvider(id: id)
    }
    
    func getProviderByName(name: String) async throws -> APIProvider { try await localProvider.getProviderByName(name: name) }
    
    func getProviderModels(id: String) async throws -> APIModelListResponse {
        if id.hasPrefix(Self.remoteProviderPrefix) {
            let providerName = String(id.dropFirst(Self.remoteProviderPrefix.count))
            return await remoteModelsForProvider(name: providerName)
        }
        
        // Local provider — merge in any additional models from peers with the same provider name
        let local = try await localProvider.getProviderModels(id: id)
        let provider = try await localProvider.getProvider(id: id)
        let remote = await remoteModelsForProvider(name: provider.displayName)
        
        let localModelIds = Set(local.models.map(\.id))
        let additional = remote.models.filter { !localModelIds.contains($0.id) }
        
        return APIModelListResponse(models: local.models + additional)
    }
    
    /// Collects all model IDs from online peers that advertise the given provider name.
    private func remoteModelsForProvider(name: String) async -> APIModelListResponse {
        let onlinePeers = await clusterManager.allOnlinePeers()
        var allModelIds: Set<String> = []
        
        for peer in onlinePeers {
            for prov in peer.providers where prov.providerName.lowercased() == name.lowercased() {
                allModelIds.formUnion(prov.modelIds)
            }
        }
        
        let models = allModelIds.sorted().map { APIModel(id: $0, name: $0) }
        return APIModelListResponse(models: models)
    }
    
    func createProvider(request: APICreateProviderRequest) async throws -> APIProvider { try await localProvider.createProvider(request: request) }
    func updateProvider(id: String, request: APIUpdateProviderRequest) async throws -> APIProvider { try await localProvider.updateProvider(id: id, request: request) }
    func deleteProvider(id: String) async throws { try await localProvider.deleteProvider(id: id) }
    func startProviderAuth(id: String) async throws -> APIProviderAuthStartResponse { try await localProvider.startProviderAuth(id: id) }
    func getProviderAuthStatus(id: String) async throws -> APIProviderAuthStatusResponse { try await localProvider.getProviderAuthStatus(id: id) }
    func logoutProviderAuth(id: String) async throws -> APIProviderAuthStatusResponse { try await localProvider.logoutProviderAuth(id: id) }
    
    // MARK: - Template, Skill, Provisioning (local only)
    
    func getTemplates() async throws -> APITemplateListResponse { try await localProvider.getTemplates() }
    func getTemplate(id: String) async throws -> APITemplate { try await localProvider.getTemplate(id: id) }
    func getSkills() async throws -> [APISkill] { try await localProvider.getSkills() }
    func getProvisioning() async throws -> APIProvisioningResponse { try await localProvider.getProvisioning() }
    
    // MARK: - System (aggregated)
    
    func getSystemStatus() async throws -> APISystemStatus {
        let localStatus = try await localProvider.getSystemStatus()
        
        let onlinePeers = await clusterManager.allOnlinePeers()
        guard !onlinePeers.isEmpty else { return localStatus }
        
        // Aggregate: sum running/queued across local + peers
        var totalRunning = localStatus.agents.running
        var totalQueued = localStatus.agents.queued
        var totalMaxConcurrent = localStatus.agents.maxConcurrent
        
        for peer in onlinePeers {
            totalRunning += peer.runningTasks
            totalQueued += peer.queuedTasks
            totalMaxConcurrent += (peer.availableSlots + peer.runningTasks)
        }
        
        return APISystemStatus(
            status: localStatus.status,
            version: localStatus.version,
            uptime: localStatus.uptime,
            agents: APIAgentCounts(
                running: totalRunning,
                paused: localStatus.agents.paused,
                queued: totalQueued,
                maxConcurrent: totalMaxConcurrent
            ),
            vms: localStatus.vms,
            resources: localStatus.resources
        )
    }
    
    func getSystemConfig() async throws -> APISystemConfig {
        try await localProvider.getSystemConfig()
    }
    
    // MARK: - Event Streaming (proxied for remote)
    
    func subscribeToTaskEvents(id: String) async throws -> AsyncStream<APITaskEvent> {
        if await remoteTaskIndex.peerId(for: id) != nil {
            // For remote tasks, return an empty stream (web UI uses activity polling instead)
            return AsyncStream { $0.finish() }
        }
        return try await localProvider.subscribeToTaskEvents(id: id)
    }
    
    func getTaskActivity(id: String, since: Int) async throws -> APIActivityResponse {
        if let peerId = await remoteTaskIndex.peerId(for: id),
           let workerTaskId = await remoteTaskIndex.workerTaskId(for: id) {
            let peers = await clusterManager.allOnlinePeers()
            guard let peer = peers.first(where: { $0.id == peerId }) else {
                return APIActivityResponse(events: [], total: 0)
            }
            let client = await getOrCreateClient(for: peer)
            return try await client.getActivity(taskId: workerTaskId, since: since)
        }
        return try await localProvider.getTaskActivity(id: id, since: since)
    }
    
    // MARK: - Helpers
    
    private func getOrCreateClient(for peer: PeerNode) async -> PeerAPIClient {
        if let existing = peerClients[peer.id] { return existing }
        let token = await clusterManager.clusterToken ?? ""
        let client = PeerAPIClient(baseURL: peer.tunnelUrl, clusterToken: token)
        peerClients[peer.id] = client
        return client
    }
    
    private func dispatchQueuedCanonicalTaskToPeer(_ task: TaskRecord) async -> Bool {
        guard task.status == .queued, task.clusterExecutionState == .none else { return false }
        
        if !task.requiresRemoteClusterExecution,
           let localStatus = try? await localProvider.getSystemStatus(),
           localStatus.vms.available > 0 {
            return false
        }
        
        let providerName = localProvider.getProviderName(for: task.providerId)
        guard providerName != "Unknown" else { return false }
        
        var executionAttempt: Int?
        var triedPeerIds: Set<String> = []
        
        while let peer = await clusterManager.reserveBestAvailablePeer(
            providerName: providerName,
            modelId: task.modelId,
            excluding: triedPeerIds
        ) {
            triedPeerIds.insert(peer.id)
            
            if executionAttempt == nil {
                task.clusterExecutionState = .dispatchingRemote
                task.clusterExecutionAttempt += 1
                try? localProvider.modelContext.save()
                localProvider.taskService.objectWillChange.send()
                executionAttempt = task.clusterExecutionAttempt
            }
            
            do {
                let client = await getOrCreateClient(for: peer)
                let response = try await client.executeNow(ClusterExecuteNowRequest(
                    canonicalTaskId: task.id,
                    executionAttempt: executionAttempt ?? task.clusterExecutionAttempt,
                    description: task.taskDescription,
                    providerName: providerName,
                    modelId: task.modelId,
                    reasoningEnabled: task.reasoningEnabled,
                    reasoningEffort: task.reasoningEffort,
                    attachedFilePaths: task.attachedFilePaths,
                    outputDirectory: task.outputDirectory,
                    planFirst: false,
                    planMarkdown: task.planMarkdown,
                    mentionedSkillNames: task.mentionedSkillNames ?? [],
                    referencedTaskIds: task.referencedTaskIds ?? [],
                    continuationSourceTaskId: task.continuationSourceTaskId,
                    contextPackId: task.retrievalContextPackId,
                    contextSuggestionIds: task.retrievalSelectedSuggestionIds ?? [],
                    contextModeOverrides: task.retrievalModeOverrides,
                    contextInlineBlocks: task.retrievalInlineContextBlocks,
                    contextAttachmentPaths: task.retrievalContextAttachmentPaths ?? []
                ))
                
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
                
                print("FederatedServiceProvider: Assigned canonical task '\(task.title)' to peer \(peer.name ?? peer.id)")
                return true
            } catch {
                await clusterManager.releaseSlot(peerId: peer.id)
                if case PeerAPIError.httpError(let statusCode) = error, statusCode == 409 {
                    print("FederatedServiceProvider: Peer \(peer.id) had no free slot at execution time")
                } else {
                    print("FederatedServiceProvider: Failed to dispatch to peer \(peer.id): \(error), trying next peer")
                    await clusterManager.markPeerOffline(tunnelId: peer.id)
                }
            }
        }
        
        if executionAttempt != nil {
            task.clusterExecutionState = .none
            try? localProvider.modelContext.save()
            localProvider.taskService.objectWillChange.send()
        }
        return false
    }
    
    private func applyRemoteExecutionSnapshot(
        canonicalTaskId: String,
        peer: PeerNode,
        workerTaskId: String,
        remoteTask: APITask
    ) async {
        guard let task = localProvider.taskService.tasks.first(where: { $0.id == canonicalTaskId }) else { return }
        
        task.clusterWorkerTaskId = workerTaskId
        task.clusterPeerId = peer.id
        task.clusterPeerName = peer.name ?? peer.subdomain
        task.startedAt = remoteTask.startedAt ?? task.startedAt
        task.completedAt = remoteTask.completedAt
        task.resultSummary = remoteTask.resultSummary
        task.errorMessage = remoteTask.errorMessage
        task.wasSuccessful = remoteTask.wasSuccessful
        task.status = localProvider.convertFromAPIStatus(remoteTask.status)
        
        switch remoteTask.status {
        case .completed, .failed, .cancelled, .timedOut, .maxIterations, .planFailed, .writebackReview:
            task.clusterExecutionState = .none
            task.clusterWorkerTaskId = nil
            task.clusterPeerId = nil
            task.clusterPeerName = nil
            await remoteTaskIndex.remove(canonicalTaskId: canonicalTaskId)
        default:
            task.clusterExecutionState = .runningRemote
        }
        
        try? localProvider.modelContext.save()
        localProvider.taskService.objectWillChange.send()
    }
    
    private func tagWithNode(_ task: APITask, peer: PeerNode, canonicalTaskId: String) -> APITask {
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
}
