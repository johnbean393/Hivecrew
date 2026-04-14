//
//  HivelinkClusterCoordinator.swift
//  Hivelink
//

import Combine
import Foundation
import HivecrewAPIModels
import HivecrewCore

/// Owns `ClusterDiscoveryService`, exposes cluster state to SwiftUI, and implements
/// `RemoteClusterDirectory` for future `RemoteTaskDispatcher` integration.
@MainActor
final class HivelinkClusterCoordinator: ObservableObject, RemoteClusterDirectory {

    private let discoveryService: ClusterDiscoveryService
    private var cancellables = Set<AnyCancellable>()

    @Published private(set) var peers: [DiscoveredClusterPeer] = []
    @Published private(set) var clusterToken: String?

    init(discoveryService: ClusterDiscoveryService = ClusterDiscoveryService()) {
        self.discoveryService = discoveryService

        discoveryService.$peers
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.peers = $0 }
            .store(in: &cancellables)

        discoveryService.$clusterToken
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.clusterToken = $0 }
            .store(in: &cancellables)
    }

    /// Loads cluster info from the Worker using the stored session token and starts health monitoring.
    func loadCluster() async {
        guard let sessionToken = RemoteAccessKeychain.retrieveSessionToken() else { return }
        let cached = RemoteAccessKeychain.retrieveClusterToken()
        await discoveryService.loadCluster(
            sessionToken: sessionToken,
            excludingTunnelId: nil,
            cachedClusterToken: cached
        )
    }

    /// Re-fetches mesh-info and re-syncs peers (pull-to-refresh).
    func refreshPeers() async {
        guard let sessionToken = RemoteAccessKeychain.retrieveSessionToken() else { return }
        await discoveryService.refreshPeersFromDirectory(sessionToken: sessionToken, excludingTunnelId: nil)
    }

    func stopDiscovery() async {
        await discoveryService.stopDiscovery()
    }

    // MARK: - RemoteClusterDirectory

    func peer(id: String) async -> RemoteClusterPeer? {
        discoveryService.peers.first { $0.id == id }.map(Self.toRemoteClusterPeer)
    }

    func reserveBestAvailablePeer(
        providerName: String,
        modelId: String,
        excluding: Set<String>
    ) async -> RemoteClusterPeer? {
        let candidates = discoveryService.peers.filter { peer in
            guard peer.status == .online else { return false }
            guard !excluding.contains(peer.id) else { return false }
            return Self.peerSupports(peer: peer, providerName: providerName, modelId: modelId)
        }
        let best = candidates.max(by: { $0.availableSlots < $1.availableSlots })
        return best.map(Self.toRemoteClusterPeer)
    }

    func reserveSpecificPeer(
        peerId: String,
        providerName: String,
        modelId: String
    ) async -> RemoteClusterPeer? {
        guard let peer = discoveryService.peers.first(where: { $0.id == peerId }) else { return nil }
        guard peer.status == .online, peer.availableSlots > 0 else { return nil }
        guard Self.peerSupports(peer: peer, providerName: providerName, modelId: modelId) else { return nil }
        return Self.toRemoteClusterPeer(peer)
    }

    func releaseSlot(peerId: String) async {
        _ = peerId
        // Hivelink does not track local slot accounting.
    }

    func markPeerOnline(tunnelId: String) async {
        _ = tunnelId
        // Health monitoring updates reachability; no separate local bookkeeping in Hivelink.
    }

    func clusterToken() async -> String? {
        discoveryService.clusterToken ?? RemoteAccessKeychain.retrieveClusterToken()
    }

    // MARK: - Helpers

    private static func peerSupports(peer: DiscoveredClusterPeer, providerName: String, modelId: String) -> Bool {
        peer.providers.contains { summary in
            summary.providerName == providerName && summary.modelIds.contains(modelId)
        }
    }

    private static func toRemoteClusterPeer(_ peer: DiscoveredClusterPeer) -> RemoteClusterPeer {
        RemoteClusterPeer(
            id: peer.id,
            subdomain: peer.subdomain,
            name: peer.name,
            tunnelUrl: peer.tunnelUrl,
            status: remoteStatus(peer.status)
        )
    }

    private static func remoteStatus(_ status: ClusterPeerReachabilityStatus) -> RemoteClusterPeerStatus {
        switch status {
        case .online: return .online
        case .offline: return .offline
        case .unreachable: return .unreachable
        }
    }
}
