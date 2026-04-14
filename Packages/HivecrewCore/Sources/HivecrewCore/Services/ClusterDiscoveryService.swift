//
//  ClusterDiscoveryService.swift
//  HivecrewCore
//
//  Cross-platform cluster peer discovery via the Worker API (mesh-info / ensure),
//  directory sync, per-peer status refresh, and health probing. No mesh participant
//  behavior (no capacity broadcasts, announcements, or cluster server role).
//

import Combine
import Foundation
import HivecrewAPIModels

// MARK: - Peer model

/// Reachability as determined by HTTP health probes and peer API bootstrap.
public enum ClusterPeerReachabilityStatus: String, Codable, Sendable {
    case online
    case offline
    case unreachable
}

/// A peer machine discovered via the Worker directory and probed locally.
public struct DiscoveredClusterPeer: Identifiable, Codable, Sendable, Hashable {
    public let id: String
    public let subdomain: String
    public let name: String?
    public var tunnelUrl: String
    public var status: ClusterPeerReachabilityStatus
    public var availableSlots: Int
    public var runningTasks: Int
    public var queuedTasks: Int
    public var lastSeen: Date
    public var providers: [PeerProviderSummary]

    public init(
        id: String,
        subdomain: String,
        name: String?,
        tunnelUrl: String,
        status: ClusterPeerReachabilityStatus,
        availableSlots: Int,
        runningTasks: Int,
        queuedTasks: Int,
        lastSeen: Date,
        providers: [PeerProviderSummary]
    ) {
        self.id = id
        self.subdomain = subdomain
        self.name = name
        self.tunnelUrl = tunnelUrl
        self.status = status
        self.availableSlots = availableSlots
        self.runningTasks = runningTasks
        self.queuedTasks = queuedTasks
        self.lastSeen = lastSeen
        self.providers = providers
    }
}

// MARK: - Service

/// Discovers cluster peers from the coordination Worker, hydrates capacity from each peer’s API,
/// and periodically re-fetches the directory and probes `/health`.
@MainActor
public final class ClusterDiscoveryService: ObservableObject {

    @Published public private(set) var peers: [DiscoveredClusterPeer] = []
    /// Cluster bearer token for calling peer Hivecrew APIs (when mesh membership is active).
    @Published public private(set) var clusterToken: String?

    private let apiClient: RemoteAccessAPIClient

    private var peerById: [String: DiscoveredClusterPeer] = [:]
    private var healthCheckTask: Task<Void, Never>?
    private var peerProbeFailureCounts: [String: Int] = [:]

    private static let healthCheckInterval: TimeInterval = 10
    private static let peerOfflineThreshold = 3
    private static let maxReportedPeerCount = 1_000_000

    private static let healthSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        return URLSession(configuration: config)
    }()

    public init(apiClient: RemoteAccessAPIClient = RemoteAccessAPIClient()) {
        self.apiClient = apiClient
    }

    // MARK: - Lifecycle

    /// Loads mesh info from the Worker, ensures a cluster exists when needed, syncs the peer directory,
    /// and bootstraps each peer’s status. On failure, optionally restores `cachedClusterToken` so callers
    /// can keep using a previously persisted token (same idea as `ClusterManager.initialize`).
    public func loadCluster(
        sessionToken: String,
        excludingTunnelId: String?,
        cachedClusterToken: String? = nil
    ) async {
        do {
            var info = try await apiClient.getClusterInfo(sessionToken: sessionToken)

            if !info.hasCluster {
                info = try await apiClient.ensureCluster(sessionToken: sessionToken)
                guard info.hasCluster else {
                    await resetState()
                    return
                }
            }

            guard let token = info.clusterToken else {
                await resetState()
                return
            }

            let directoryPeers = info.peers.filter { $0.tunnelId != excludingTunnelId }

            clusterToken = token
            _ = RemoteAccessKeychain.storeClusterToken(token)
            startHealthMonitoring()
            await bootstrapPeersFromDirectory(directoryPeers, clusterToken: token)
        } catch {
            print("ClusterDiscoveryService: Failed to get cluster info: \(error)")
            if let cached = cachedClusterToken {
                clusterToken = cached
                startHealthMonitoring()
            } else {
                await resetState()
            }
        }
    }

    /// Re-fetches mesh-info and re-syncs peers (same path as periodic refresh in `ClusterManager`).
    public func refreshPeersFromDirectory(sessionToken: String, excludingTunnelId: String?) async {
        do {
            let info = try await apiClient.getClusterInfo(sessionToken: sessionToken)
            guard info.hasCluster, let token = info.clusterToken else { return }

            let directoryPeers = info.peers.filter { $0.tunnelId != excludingTunnelId }

            self.clusterToken = token
            _ = RemoteAccessKeychain.storeClusterToken(token)

            await bootstrapPeersFromDirectory(directoryPeers, clusterToken: token)
        } catch {
            print("ClusterDiscoveryService: Failed to refresh peer directory: \(error)")
        }
    }

    public func startHealthMonitoring() {
        healthCheckTask?.cancel()
        healthCheckTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.healthCheckInterval))
                guard !Task.isCancelled else { break }
                await self?.runHealthCycle()
            }
        }
    }

    public func stopHealthMonitoring() {
        healthCheckTask?.cancel()
        healthCheckTask = nil
    }

    /// Stops timers and clears published state (e.g. sign-out or tunnel teardown).
    public func stopDiscovery() async {
        stopHealthMonitoring()
        peerProbeFailureCounts.removeAll()
        peerById.removeAll()
        clusterToken = nil
        publishPeers()
    }

    public func peer(withTunnelId id: String) -> DiscoveredClusterPeer? {
        peerById[id]
    }

    // MARK: - Bootstrap

    private func bootstrapPeersFromDirectory(
        _ directoryPeers: [ClusterPeerInfo],
        clusterToken: String
    ) async {
        syncPeersFromDirectory(directoryPeers)
        guard !directoryPeers.isEmpty else { return }

        // Sequential refresh avoids Swift 6 task-group isolation issues with @MainActor state.
        for peer in directoryPeers {
            await refreshPeerFromDirectory(peer, clusterToken: clusterToken)
        }
    }

    private func syncPeersFromDirectory(_ directoryPeers: [ClusterPeerInfo]) {
        let directoryIds = Set(directoryPeers.map(\.tunnelId))
        peerById = peerById.filter { directoryIds.contains($0.key) }

        for peer in directoryPeers {
            let existing = peerById[peer.tunnelId]
            peerById[peer.tunnelId] = DiscoveredClusterPeer(
                id: peer.tunnelId,
                subdomain: peer.subdomain,
                name: peer.name,
                tunnelUrl: peer.url,
                status: existing?.status ?? .offline,
                availableSlots: existing?.availableSlots ?? 0,
                runningTasks: existing?.runningTasks ?? 0,
                queuedTasks: existing?.queuedTasks ?? 0,
                lastSeen: existing?.lastSeen ?? Self.heartbeatDate(peer.lastHeartbeat),
                providers: existing?.providers ?? []
            )
        }

        publishPeers()
    }

    private func refreshPeerFromDirectory(_ peer: ClusterPeerInfo, clusterToken: String) async {
        let client = PeerAPIClient(baseURL: peer.url, clusterToken: clusterToken)

        do {
            let clusterStatus = try await client.getClusterStatus()
            let existing = peerById[peer.tunnelId]
            let availableSlots = Self.sanitizeReportedCount(
                clusterStatus.localAvailableSlots,
                label: "availableSlots",
                peerId: peer.tunnelId
            )
            let runningTasks = Self.sanitizeReportedCount(
                clusterStatus.localRunning,
                label: "runningTasks",
                peerId: peer.tunnelId
            )
            let queuedTasks = Self.sanitizeReportedCount(
                clusterStatus.localQueued,
                label: "queuedTasks",
                peerId: peer.tunnelId
            )

            peerById[peer.tunnelId] = DiscoveredClusterPeer(
                id: peer.tunnelId,
                subdomain: peer.subdomain,
                name: peer.name,
                tunnelUrl: peer.url,
                status: .online,
                availableSlots: availableSlots,
                runningTasks: runningTasks,
                queuedTasks: queuedTasks,
                lastSeen: Date(),
                providers: existing?.providers ?? []
            )
            publishPeers()

            let needsModelFetch = peerById[peer.tunnelId]?.providers.isEmpty != false
                || peerById[peer.tunnelId]?.providers.allSatisfy { $0.modelIds.isEmpty } == true
            if needsModelFetch {
                await fetchPeerCapabilities(
                    peerId: peer.tunnelId,
                    baseURL: peer.url,
                    clusterToken: clusterToken
                )
            }
        } catch {
            let existing = peerById[peer.tunnelId]
            peerById[peer.tunnelId] = DiscoveredClusterPeer(
                id: peer.tunnelId,
                subdomain: peer.subdomain,
                name: peer.name,
                tunnelUrl: peer.url,
                status: .offline,
                availableSlots: 0,
                runningTasks: 0,
                queuedTasks: 0,
                lastSeen: existing?.lastSeen ?? Self.heartbeatDate(peer.lastHeartbeat),
                providers: existing?.providers ?? []
            )
            publishPeers()
            print("ClusterDiscoveryService: Failed to bootstrap peer \(peer.tunnelId): \(error)")
        }
    }

    private func fetchPeerCapabilities(peerId: String, baseURL: String, clusterToken: String) async {
        let client = PeerAPIClient(baseURL: baseURL, clusterToken: clusterToken)
        do {
            let capabilities = try await client.fetchProviderCapabilities()
            guard var node = peerById[peerId] else { return }
            node.providers = capabilities
            peerById[peerId] = node
            publishPeers()
            print("ClusterDiscoveryService: Fetched \(capabilities.count) provider(s) from peer \(node.name ?? peerId)")
        } catch {
            print("ClusterDiscoveryService: Failed to fetch capabilities from peer \(peerId): \(error)")
        }
    }

    private static func heartbeatDate(_ lastHeartbeat: Double) -> Date {
        Date(timeIntervalSince1970: lastHeartbeat / 1000)
    }

    private static func sanitizeReportedCount(_ value: Int, label: String, peerId: String) -> Int {
        if value < 0 {
            print("ClusterDiscoveryService: Received negative \(label) from peer \(peerId); clamping to 0")
            return 0
        }
        if value > maxReportedPeerCount {
            print("ClusterDiscoveryService: Received suspicious \(label)=\(value) from peer \(peerId); clamping to \(maxReportedPeerCount)")
            return maxReportedPeerCount
        }
        return value
    }

    // MARK: - Health

    private func runHealthCycle() async {
        await refreshFromWorkerIfPossible()
        await probeAllPeers()
    }

    private func refreshFromWorkerIfPossible() async {
        guard clusterToken != nil,
              let sessionToken = RemoteAccessKeychain.retrieveSessionToken() else {
            return
        }

        let myTunnelId = RemoteAccessKeychain.retrieveTunnelId()
        await refreshPeersFromDirectory(sessionToken: sessionToken, excludingTunnelId: myTunnelId)
    }

    private func probeAllPeers() async {
        guard let token = clusterToken else { return }

        let currentPeers = Array(peerById.values)
        guard !currentPeers.isEmpty else { return }

        let results = await withTaskGroup(of: (String, Bool).self) { group in
            for peer in currentPeers {
                let id = peer.id
                let url = peer.tunnelUrl
                group.addTask {
                    (id, await Self.probePeerHealth(url: url))
                }
            }
            var collected: [(String, Bool)] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        var stateChanged = false
        var peersToRefreshCapabilities: [(id: String, url: String)] = []

        for (id, reachable) in results {
            guard var peer = peerById[id] else { continue }
            if reachable && peer.status != .online {
                peerProbeFailureCounts[id] = 0
                let wasOffline = peer.status == .offline
                peer.status = .online
                peer.lastSeen = Date()
                peerById[id] = peer
                stateChanged = true
                print("ClusterDiscoveryService: Health probe passed for \(peer.name ?? id), marking online")
                if wasOffline {
                    peersToRefreshCapabilities.append((id: id, url: peer.tunnelUrl))
                }
            } else if !reachable {
                let failureCount = (peerProbeFailureCounts[id] ?? 0) + 1
                peerProbeFailureCounts[id] = failureCount

                if failureCount >= Self.peerOfflineThreshold, peer.status != .offline {
                    peer.status = .offline
                    peerById[id] = peer
                    stateChanged = true
                    print("ClusterDiscoveryService: Health probe failed for \(peer.name ?? id) \(failureCount)x, marking offline")
                } else if failureCount < Self.peerOfflineThreshold, peer.status == .online {
                    peer.status = .unreachable
                    peerById[id] = peer
                    stateChanged = true
                    print("ClusterDiscoveryService: Health probe failed for \(peer.name ?? id) \(failureCount)x, marking unreachable")
                }
            }
        }

        for peer in peersToRefreshCapabilities {
            await fetchPeerCapabilities(peerId: peer.id, baseURL: peer.url, clusterToken: token)
        }

        if stateChanged {
            publishPeers()
        }
    }

    private static func probePeerHealth(url: String) async -> Bool {
        guard let healthURL = URL(string: "\(url)/health") else { return false }
        do {
            let (_, response) = try await healthSession.data(from: healthURL)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Private

    private func resetState() async {
        stopHealthMonitoring()
        peerProbeFailureCounts.removeAll()
        peerById.removeAll()
        clusterToken = nil
        publishPeers()
    }

    private func publishPeers() {
        peers = peerById.values.sorted { $0.id < $1.id }
    }
}
