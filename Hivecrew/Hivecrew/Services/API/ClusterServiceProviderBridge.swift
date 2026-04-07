//
//  ClusterServiceProviderBridge.swift
//  Hivecrew
//
//  Bridges ClusterServiceProvider protocol to ClusterManager for the API server
//

import Foundation
import HivecrewAPI

final class ClusterServiceProviderBridge: ClusterServiceProvider, @unchecked Sendable {
    
    private let clusterManager: ClusterManager
    private let remoteTaskIndex: RemoteTaskIndex
    
    init(clusterManager: ClusterManager, remoteTaskIndex: RemoteTaskIndex) {
        self.clusterManager = clusterManager
        self.remoteTaskIndex = remoteTaskIndex
    }
    
    func handleAnnouncement(_ announcement: PeerAnnouncement) async throws {
        await clusterManager.updatePeerCapacity(announcement)
    }
    
    func handleTaskUpdate(_ update: PeerTaskUpdate) async throws {
        await remoteTaskIndex.update(taskId: update.taskId, task: update.task)
    }
    
    func handleDeparture(tunnelId: String) async throws {
        await clusterManager.markPeerOffline(tunnelId: tunnelId)
    }
    
    func getClusterStatus() async throws -> APIClusterStatus {
        let role = await clusterManager.role
        let peers = await clusterManager.peers
        
        let localMax = VMConcurrencyPolicy.effectiveMaxConcurrentVMs()
        let localRunning = await MainActor.run {
            APIServerManager.shared.taskServiceRef?.runningAgents.count ?? 0
        }
        
        var totalCapacity = localMax
        var totalRunning = localRunning
        var totalQueued = 0
        
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
            localRunning: localRunning,
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
}
