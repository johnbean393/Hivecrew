//
//  ClusterServiceProviderBridge.swift
//  Hivecrew
//
//  Bridges ClusterServiceProvider protocol to ClusterManager for the API server
//

import Foundation
import Combine
import SwiftData
import HivecrewAPI

final class ClusterServiceProviderBridge: ClusterServiceProvider, @unchecked Sendable {
    
    private let localProvider: APIServiceProviderBridge
    private let clusterManager: ClusterManager
    private let remoteTaskIndex: RemoteTaskIndex
    
    init(
        localProvider: APIServiceProviderBridge,
        clusterManager: ClusterManager,
        remoteTaskIndex: RemoteTaskIndex
    ) {
        self.localProvider = localProvider
        self.clusterManager = clusterManager
        self.remoteTaskIndex = remoteTaskIndex
    }
    
    func handleAnnouncement(_ announcement: PeerAnnouncement) async throws {
        await clusterManager.updatePeerCapacity(announcement)
    }
    
    func handleTaskUpdate(_ update: PeerTaskUpdate) async throws {
        guard let canonicalTaskId = await remoteTaskIndex.canonicalTaskId(
            peerId: update.tunnelId,
            workerTaskId: update.workerTaskId
        ) else {
            return
        }
        
        let peers = await clusterManager.peers
        let peer = peers[update.tunnelId]
        let taggedTask = APITask(
            id: canonicalTaskId,
            title: update.task.title,
            description: update.task.description,
            status: update.task.status,
            providerName: update.task.providerName,
            modelId: update.task.modelId,
            reasoningEnabled: update.task.reasoningEnabled,
            reasoningEffort: update.task.reasoningEffort,
            createdAt: update.task.createdAt,
            startedAt: update.task.startedAt,
            completedAt: update.task.completedAt,
            resultSummary: update.task.resultSummary,
            errorMessage: update.task.errorMessage,
            inputFiles: update.task.inputFiles,
            outputFiles: update.task.outputFiles,
            wasSuccessful: update.task.wasSuccessful,
            vmId: update.task.vmId,
            referencedTaskIds: update.task.referencedTaskIds,
            continuationSourceTaskId: update.task.continuationSourceTaskId,
            duration: update.task.duration,
            stepCount: update.task.stepCount,
            tokenUsage: update.task.tokenUsage,
            planMarkdown: update.task.planMarkdown,
            planFirst: update.task.planFirst,
            contextPackId: update.task.contextPackId,
            contextItemCount: update.task.contextItemCount,
            contextAttachmentCount: update.task.contextAttachmentCount,
            pendingQuestion: update.task.pendingQuestion,
            pendingPermission: update.task.pendingPermission,
            pendingWriteback: update.task.pendingWriteback,
            pendingWritebackCount: update.task.pendingWritebackCount,
            appliedWritebackPaths: update.task.appliedWritebackPaths,
            nodeId: update.tunnelId,
            nodeName: peer?.name ?? peer?.subdomain
        )
        
        await remoteTaskIndex.update(canonicalTaskId: canonicalTaskId, task: taggedTask)
        await MainActor.run {
            guard let taskService = APIServerManager.shared.taskServiceRef,
                  let task = taskService.tasks.first(where: { $0.id == canonicalTaskId }),
                  task.clusterExecutionAttempt == update.executionAttempt else {
                return
            }
            
            task.clusterWorkerTaskId = update.workerTaskId
            task.clusterPeerId = update.tunnelId
            task.clusterPeerName = peer?.name ?? peer?.subdomain
            task.startedAt = update.task.startedAt ?? task.startedAt
            task.completedAt = update.task.completedAt
            task.resultSummary = update.task.resultSummary
            task.errorMessage = update.task.errorMessage
            task.wasSuccessful = update.task.wasSuccessful
            
            switch update.task.status {
            case .running, .paused, .waitingForVM, .planning, .planReview:
                task.status = localProvider.convertFromAPIStatus(update.task.status)
                task.clusterExecutionState = .runningRemote
            case .completed, .failed, .cancelled, .timedOut, .maxIterations, .planFailed, .writebackReview:
                task.status = localProvider.convertFromAPIStatus(update.task.status)
                task.clusterExecutionState = .none
                Task {
                    guard let peer else { return }
                    let client = PeerAPIClient(
                        baseURL: peer.tunnelUrl,
                        clusterToken: await self.clusterManager.clusterToken ?? ""
                    )
                    let imported = await RemoteExecutionArtifactImporter.importArtifacts(
                        task: task,
                        remoteTask: update.task,
                        peer: peer,
                        workerTaskId: update.workerTaskId,
                        client: client,
                        taskService: localProvider.taskService,
                        modelContext: localProvider.modelContext
                    )
                    if imported {
                        task.clusterWorkerTaskId = nil
                        await self.remoteTaskIndex.remove(canonicalTaskId: canonicalTaskId)
                    }
                }
            case .queued:
                task.status = .queued
                task.clusterExecutionState = .recoveringRemote
            }
            
            try? taskService.modelContext?.save()
            taskService.objectWillChange.send()
        }
    }
    
    func handleDeparture(tunnelId: String) async throws {
        await clusterManager.markPeerOffline(tunnelId: tunnelId)
    }
    
    func executeNow(_ request: ClusterExecuteNowRequest) async throws -> ClusterExecuteNowResponse {
        let task = try await localProvider.createClusterExecutionTask(
            canonicalTaskId: request.canonicalTaskId,
            ownerTunnelId: request.ownerTunnelId,
            executionAttempt: request.executionAttempt,
            description: request.description,
            providerName: request.providerName,
            modelId: request.modelId,
            reasoningEnabled: request.reasoningEnabled,
            reasoningEffort: request.reasoningEffort,
            attachedFilePaths: request.attachedFilePaths,
            outputDirectory: request.outputDirectory,
            planMarkdown: request.planMarkdown,
            mentionedSkillNames: request.mentionedSkillNames,
            referencedTaskIds: request.referencedTaskIds,
            continuationSourceTaskId: request.continuationSourceTaskId,
            contextPackId: request.contextPackId,
            contextSuggestionIds: request.contextSuggestionIds,
            contextModeOverrides: request.contextModeOverrides,
            contextInlineBlocks: request.contextInlineBlocks,
            contextAttachmentPaths: request.contextAttachmentPaths
        )
        return ClusterExecuteNowResponse(workerTaskId: task.id, task: task)
    }
    
    func getClusterStatus() async throws -> APIClusterStatus {
        let role = await clusterManager.role
        let peers = await clusterManager.peers
        let localProviders = await localProviderSummaries()
        
        let localMax = VMConcurrencyPolicy.effectiveMaxConcurrentVMs()
        let (localRunning, localQueued) = await MainActor.run {
            let taskService = APIServerManager.shared.taskServiceRef
            return (
                taskService?.runningAgents.count ?? 0,
                taskService?.tasks.filter { $0.status == .queued || $0.status == .waitingForVM }.count ?? 0
            )
        }
        let localAvailableSlots = max(0, localMax - localRunning)
        
        var totalCapacity = localMax
        var totalRunning = localRunning
        var totalQueued = localQueued
        
        let peerList: [APIClusterPeer] = peers.values.map { node in
            if node.status == .online {
                totalCapacity += (node.availableSlots + node.runningTasks)
                totalRunning += node.runningTasks
                totalQueued += node.queuedTasks
            }
            
            return APIClusterPeer(
                tunnelId: node.id,
                subdomain: node.subdomain,
                name: node.name,
                status: node.status.rawValue,
                availableSlots: node.availableSlots,
                runningTasks: node.runningTasks,
                lastSeen: node.lastSeen
            )
        }
        
        return APIClusterStatus(
            role: role.rawValue,
            totalCapacity: totalCapacity,
            totalRunning: totalRunning,
            totalQueued: totalQueued,
            localCapacity: localMax,
            localAvailableSlots: localAvailableSlots,
            localRunning: localRunning,
            localQueued: localQueued,
            localProviders: localProviders,
            peers: peerList
        )
    }
    
    func getClusterPeers() async throws -> [APIClusterPeer] {
        let peers = await clusterManager.peers
        return peers.values.map { node in
            APIClusterPeer(
                tunnelId: node.id,
                subdomain: node.subdomain,
                name: node.name,
                status: node.status.rawValue,
                availableSlots: node.availableSlots,
                runningTasks: node.runningTasks,
                lastSeen: node.lastSeen
            )
        }
    }

    private func localProviderSummaries() async -> [PeerProviderSummary] {
        let descriptor = FetchDescriptor<LLMProviderRecord>()
        let providers = (try? localProvider.modelContext.fetch(descriptor)) ?? []
        guard !providers.isEmpty else { return [] }

        var summaries: [PeerProviderSummary] = []
        summaries.reserveCapacity(providers.count)

        for provider in providers {
            do {
                let models = try await localProvider.fetchModelsFromProvider(provider)
                summaries.append(
                    PeerProviderSummary(
                        providerName: provider.displayName,
                        modelIds: models.map(\.id)
                    )
                )
            } catch {
                print("ClusterServiceProviderBridge: Failed to load models for local provider \(provider.displayName): \(error)")
                summaries.append(
                    PeerProviderSummary(
                        providerName: provider.displayName,
                        modelIds: []
                    )
                )
            }
        }

        return summaries
    }
}
