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
import HivecrewCore

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
        let canonicalTaskId = await remoteTaskIndex.canonicalTaskId(
            peerId: update.tunnelId,
            workerTaskId: update.workerTaskId
        ) ?? update.canonicalTaskId

        guard !canonicalTaskId.isEmpty else { return }
        let peers = await clusterManager.peers
        let peer = peers[update.tunnelId]

        let shouldApply = await MainActor.run {
            guard let taskService = APIServerManager.shared.taskServiceRef,
                  let task = taskService.tasks.first(where: { $0.id == canonicalTaskId }) else {
                return false
            }
            return task.clusterExecutionAttempt == update.executionAttempt
        }
        guard shouldApply else {
            let isTerminal: Bool
            switch update.task.status {
            case .completed, .failed, .cancelled, .timedOut, .maxIterations, .planFailed, .writebackReview:
                isTerminal = true
            case .queued, .waitingForVM, .running, .paused, .planning, .planReview:
                isTerminal = false
            }
            if isTerminal, let peer {
                Task {
                    await self.importSupersededArtifacts(
                        canonicalTaskId: canonicalTaskId,
                        executionAttempt: update.executionAttempt,
                        remoteTask: update.task,
                        workerTaskId: update.workerTaskId,
                        peer: peer
                    )
                }
            }
            return
        }

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
        
        if await remoteTaskIndex.peerId(for: canonicalTaskId) == nil {
            await remoteTaskIndex.register(
                canonicalTaskId: canonicalTaskId,
                peerId: update.tunnelId,
                workerTaskId: update.workerTaskId,
                task: taggedTask
            )
        } else {
            await remoteTaskIndex.update(canonicalTaskId: canonicalTaskId, task: taggedTask)
        }
        await MainActor.run {
            guard let taskService = APIServerManager.shared.taskServiceRef,
                  let task = taskService.tasks.first(where: { $0.id == canonicalTaskId }) else {
                return
            }
            
            task.clusterWorkerTaskId = update.workerTaskId
            task.clusterLeaseId = update.ownerLeaseId ?? task.clusterLeaseId ?? update.workerTaskId
            task.clusterPeerId = update.tunnelId
            task.clusterPeerName = peer?.name ?? peer?.subdomain
            task.startedAt = update.task.startedAt ?? task.startedAt
            task.completedAt = update.task.completedAt
            task.resultSummary = update.task.resultSummary
            task.errorMessage = update.task.errorMessage
            task.wasSuccessful = update.task.wasSuccessful
            task.clusterLastRemoteContactAt = Date()
            task.clusterLeaseFirstFailureAt = nil
            task.clusterLeaseFailureCount = 0
            
            switch update.task.status {
            case .running, .paused, .waitingForVM, .planning, .planReview:
                task.status = localProvider.convertFromAPIStatus(update.task.status)
                task.clusterExecutionState = .runningRemote
                task.remoteLeaseState = .running
            case .completed, .failed, .cancelled, .timedOut, .maxIterations, .planFailed, .writebackReview:
                task.status = localProvider.convertFromAPIStatus(update.task.status)
                task.clusterExecutionState = .none
                task.remoteLeaseState = .completedAwaitingImport
                Task {
                    guard let peer else { return }
                    let client = PeerAPIClient(
                        baseURL: peer.tunnelUrl,
                        clusterToken: await self.currentClusterToken()
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
                        task.clusterLeaseId = nil
                        task.clusterPeerId = nil
                        task.clusterLastRemoteContactAt = nil
                        task.clusterLeaseFirstFailureAt = nil
                        task.clusterLeaseFailureCount = 0
                        task.remoteLeaseState = .none
                        await self.remoteTaskIndex.remove(canonicalTaskId: canonicalTaskId)
                    }
                }
            case .queued:
                task.status = .queued
                task.clusterExecutionState = .recoveringRemote
                task.remoteLeaseState = .recovering
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
            ownerName: request.ownerName,
            ownerLeaseId: request.ownerLeaseId,
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
            contextAttachmentPaths: request.contextAttachmentPaths,
            referenceContextBlocks: request.referenceContextBlocks,
            referenceFiles: request.referenceFiles
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

    private func currentClusterToken() async -> String {
        if let token = await clusterManager.clusterToken, !token.isEmpty {
            return token
        }
        return RemoteAccessKeychain.retrieveClusterToken() ?? ""
    }

    private func importSupersededArtifacts(
        canonicalTaskId: String,
        executionAttempt: Int,
        remoteTask: APITask,
        workerTaskId: String,
        peer: PeerNode
    ) async {
        let destination = AppPaths.supersededClusterAttemptDirectory(
            canonicalTaskId: canonicalTaskId,
            executionAttempt: executionAttempt
        )
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let client = PeerAPIClient(
            baseURL: peer.tunnelUrl,
            clusterToken: await currentClusterToken()
        )

        var importedPaths: [String] = []

        do {
            let outputDirectory = destination.appendingPathComponent("outputs", isDirectory: true)
            try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            for file in remoteTask.outputFiles {
                let blob = try await client.downloadTaskFile(taskId: workerTaskId, filename: file.name, isInput: false)
                let outputURL = outputDirectory.appendingPathComponent(file.name)
                try blob.data.write(to: outputURL)
                importedPaths.append(outputURL.path)
            }
        } catch {
            print("ClusterServiceProviderBridge: Failed importing superseded outputs for \(canonicalTaskId) attempt \(executionAttempt): \(error)")
        }

        do {
            let traceDirectory = destination.appendingPathComponent("trace", isDirectory: true)
            let bundle = try await client.getTraceBundle(taskId: workerTaskId, canonicalTaskId: canonicalTaskId)
            try? FileManager.default.createDirectory(at: traceDirectory, withIntermediateDirectories: true)
            for file in bundle.files {
                let blob = try await client.downloadTraceFile(taskId: workerTaskId, relativePath: file.path)
                let destinationURL = traceDirectory.appendingPathComponent(file.path)
                try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try blob.data.write(to: destinationURL)
            }
            importedPaths.append(traceDirectory.path)
        } catch {
            print("ClusterServiceProviderBridge: Failed importing superseded trace for \(canonicalTaskId) attempt \(executionAttempt): \(error)")
        }

        guard !importedPaths.isEmpty else { return }

        await MainActor.run {
            guard let taskService = APIServerManager.shared.taskServiceRef,
                  let task = taskService.tasks.first(where: { $0.id == canonicalTaskId }) else {
                return
            }
            var existing = task.clusterSupersededArtifactDirectories ?? []
            if !existing.contains(destination.path) {
                existing.append(destination.path)
                task.clusterSupersededArtifactDirectories = existing
                if task.errorMessage?.contains("superseded") != true {
                    task.errorMessage = "A superseded remote attempt produced quarantined artifacts."
                }
                try? taskService.modelContext?.save()
                taskService.objectWillChange.send()
            }
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
