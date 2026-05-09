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
        ensureOwnerTunnelId()
        let cached = RemoteAccessKeychain.retrieveClusterToken()
        await discoveryService.loadCluster(
            sessionToken: sessionToken,
            excludingTunnelId: RemoteAccessKeychain.retrieveTunnelId(),
            cachedClusterToken: cached
        )
    }

    /// Hivelink doesn't run a real tunnel, but the dispatcher needs a stable owner
    /// identity. Generate one on first launch and persist it in the keychain.
    private func ensureOwnerTunnelId() {
        if RemoteAccessKeychain.retrieveTunnelId() == nil {
            _ = RemoteAccessKeychain.storeTunnelId("hivelink-\(UUID().uuidString)")
        }
    }

    /// Re-fetches mesh-info and re-syncs peers (pull-to-refresh).
    func refreshPeers() async {
        guard let sessionToken = RemoteAccessKeychain.retrieveSessionToken() else { return }
        await discoveryService.refreshPeersFromDirectory(
            sessionToken: sessionToken,
            excludingTunnelId: RemoteAccessKeychain.retrieveTunnelId()
        )
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
            guard peer.availableSlots > 0 else { return false }
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

    func reserveBestAvailablePeer(
        providerName: String,
        modelId: String,
        excluding: Set<String>,
        runtimeKind: RemoteAgentRuntimeKind
    ) async -> RemoteClusterPeer? {
        let candidates = discoveryService.peers.filter { peer in
            guard peer.status == .online else { return false }
            guard !excluding.contains(peer.id) else { return false }
            guard Self.peerSupports(peer: peer, providerName: providerName, modelId: modelId) else { return false }
            return Self.peerHasRuntimeCapacity(peer, runtimeKind: runtimeKind)
        }
        let best = candidates.max {
            Self.runtimeAvailableSlots($0, runtimeKind: runtimeKind)
                < Self.runtimeAvailableSlots($1, runtimeKind: runtimeKind)
        }
        return best.map(Self.toRemoteClusterPeer)
    }

    func reserveSpecificPeer(
        peerId: String,
        providerName: String,
        modelId: String,
        runtimeKind: RemoteAgentRuntimeKind
    ) async -> RemoteClusterPeer? {
        guard let peer = discoveryService.peers.first(where: { $0.id == peerId }) else { return nil }
        guard peer.status == .online else { return nil }
        guard Self.peerSupports(peer: peer, providerName: providerName, modelId: modelId) else { return nil }
        guard Self.peerHasRuntimeCapacity(peer, runtimeKind: runtimeKind) else { return nil }
        return Self.toRemoteClusterPeer(peer)
    }

    func releaseSlot(peerId: String) async {
        _ = peerId
        // Hivelink does not track local slot accounting.
    }

    func releaseSlot(peerId: String, runtimeKind: RemoteAgentRuntimeKind) async {
        _ = peerId
        _ = runtimeKind
        // Hivelink does not track local slot accounting.
    }

    func eligiblePeerCount(
        providerName: String,
        modelId: String,
        excluding: Set<String>,
        runtimeKind: RemoteAgentRuntimeKind?
    ) async -> Int? {
        discoveryService.peers.filter { peer in
            guard peer.status == .online else { return false }
            guard !excluding.contains(peer.id) else { return false }
            guard Self.peerSupports(peer: peer, providerName: providerName, modelId: modelId) else { return false }
            if let runtimeKind {
                return Self.peerHasRuntimeCapacity(peer, runtimeKind: runtimeKind)
            }
            return peer.availableSlots > 0
        }.count
    }

    func markPeerOnline(tunnelId: String) async {
        _ = tunnelId
        // Health monitoring updates reachability; no separate local bookkeeping in Hivelink.
    }

    func clusterToken() async -> String? {
        discoveryService.clusterToken ?? RemoteAccessKeychain.retrieveClusterToken()
    }

    // MARK: - Model Capabilities

    /// Fetches the reasoning capability for a specific model from the first online peer that supports it.
    func fetchReasoningCapability(providerName: String, modelId: String) async -> APIReasoningCapability {
        guard let token = await clusterToken() else { return APIReasoningCapability() }

        let candidate = peers.first { peer in
            peer.status == .online && Self.peerSupports(peer: peer, providerName: providerName, modelId: modelId)
        }
        guard let peer = candidate else { return APIReasoningCapability() }

        let client = PeerAPIClient(baseURL: peer.tunnelUrl, clusterToken: token)
        do {
            let providersResponse = try await client.getProviders()
            guard let apiProvider = providersResponse.providers.first(where: {
                $0.displayName == providerName
            }) else { return APIReasoningCapability() }

            let modelsResponse = try await client.getProviderModels(providerId: apiProvider.id)
            if let model = modelsResponse.models.first(where: { $0.id == modelId }) {
                return model.reasoningCapability
            }
        } catch {
            // Fallback handled by caller
        }
        return APIReasoningCapability()
    }

    // MARK: - Helpers

    private static func peerSupports(peer: DiscoveredClusterPeer, providerName: String, modelId: String) -> Bool {
        peer.providers.contains { summary in
            summary.providerName == providerName && summary.modelIds.contains(modelId)
        }
    }

    private static func peerHasRuntimeCapacity(
        _ peer: DiscoveredClusterPeer,
        runtimeKind: RemoteAgentRuntimeKind
    ) -> Bool {
        guard !peer.runtimes.isEmpty else {
            return peer.availableSlots > 0
        }
        guard let runtime = peer.runtimes.first(where: { $0.runtimeKind == apiRuntimeKind(runtimeKind) }) else {
            return false
        }
        return runtime.supported && runtime.setupStatus == .ready && runtime.availableSlots > 0
    }

    private static func runtimeAvailableSlots(
        _ peer: DiscoveredClusterPeer,
        runtimeKind: RemoteAgentRuntimeKind
    ) -> Int {
        peer.runtimes.first { $0.runtimeKind == apiRuntimeKind(runtimeKind) }?.availableSlots
            ?? peer.availableSlots
    }

    private static func apiRuntimeKind(_ runtimeKind: RemoteAgentRuntimeKind) -> APIAgentRuntimeKind {
        switch runtimeKind {
        case .fast: return .fast
        case .app: return .app
        case .isolatedVM: return .isolatedVM
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
        case .dnsUnavailable: return .dnsUnavailable
        }
    }
}
