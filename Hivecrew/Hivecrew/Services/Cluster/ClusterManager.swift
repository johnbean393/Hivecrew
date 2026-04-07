//
//  ClusterManager.swift
//  Hivecrew
//
//  Central actor managing cluster state: role, peer table, and dispatch decisions
//

import Combine
import Foundation
import HivecrewAPI

// MARK: - Cluster Role

enum ClusterRole: String, Sendable {
    case none
    case coordinator
    case worker
}

// MARK: - Observable Status

@MainActor
final class ClusterStatus: ObservableObject {
    static let shared = ClusterStatus()
    
    @Published var role: ClusterRole = .none
    @Published var peers: [PeerNode] = []
    @Published var coordinatorUrl: String?
    
    private init() {}
    
    func update(role: ClusterRole, peers: [PeerNode] = [], coordinatorUrl: String? = nil) {
        self.role = role
        self.peers = peers
        self.coordinatorUrl = coordinatorUrl
    }
    
    func updatePeers(_ peers: [PeerNode]) {
        self.peers = peers
    }
    
    func reset() {
        role = .none
        peers = []
        coordinatorUrl = nil
    }
}

// MARK: - Cluster Manager

actor ClusterManager {
    static let shared = ClusterManager()
    
    private(set) var role: ClusterRole = .none
    private(set) var peers: [String: PeerNode] = [:]
    private(set) var coordinatorUrl: String?
    private(set) var clusterToken: String?
    
    private let apiClient = RemoteAccessAPIClient()
    private var announcer: ClusterAnnouncer?
    private var capacityObserver: Any?
    private var healthCheckTask: Task<Void, Never>?
    
    private static let healthCheckInterval: TimeInterval = 10
    private static let dispatchOrderKey = "clusterDispatchOrder"
    
    private static let healthSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        return URLSession(configuration: config)
    }()
    
    private init() {
        // Listen for local capacity changes (task started/finished)
        capacityObserver = NotificationCenter.default.addObserver(
            forName: .clusterCapacityChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task {
                await self.notifyCapacityChanged()
            }
        }
    }
    
    // MARK: - Initialization
    
    /// Discover cluster state from the Cloudflare Worker and configure accordingly.
    /// Called once during app startup after remote access is connected.
    func initialize() async {
        guard let sessionToken = RemoteAccessKeychain.retrieveSessionToken() else {
            await configure(role: .none, clusterToken: nil, coordinatorUrl: nil)
            return
        }
        
        do {
            let info = try await apiClient.getClusterInfo(sessionToken: sessionToken)
            
            guard info.hasCluster else {
                await configure(role: .none, clusterToken: nil, coordinatorUrl: nil)
                return
            }
            
            guard let token = info.clusterToken else {
                await configure(role: .none, clusterToken: nil, coordinatorUrl: nil)
                return
            }
            
            // Derive role by comparing our local tunnelId against the coordinator's
            let myTunnelId = RemoteAccessKeychain.retrieveTunnelId()
            let isCoordinator = myTunnelId != nil && myTunnelId == info.coordinatorTunnelId
            let directoryPeers = info.peers.filter { $0.tunnelId != myTunnelId }
            
            if isCoordinator {
                await configure(role: .coordinator, clusterToken: token, coordinatorUrl: info.coordinatorUrl)
                RemoteAccessKeychain.storeClusterToken(token)
                await bootstrapPeersFromDirectory(directoryPeers, clusterToken: token)
            } else {
                guard let coordUrl = info.coordinatorUrl else {
                    await configure(role: .none, clusterToken: nil, coordinatorUrl: nil)
                    return
                }
                await configure(role: .worker, clusterToken: token, coordinatorUrl: coordUrl)
                RemoteAccessKeychain.storeClusterToken(token)
                RemoteAccessKeychain.storeCoordinatorUrl(coordUrl)
                startAnnouncer(coordinatorUrl: coordUrl, clusterToken: token)
            }
        } catch {
            print("ClusterManager: Failed to get cluster info: \(error)")
            
            // Fall back to cached credentials
            if let cachedToken = RemoteAccessKeychain.retrieveClusterToken(),
               let cachedUrl = RemoteAccessKeychain.retrieveCoordinatorUrl() {
                await configure(role: .worker, clusterToken: cachedToken, coordinatorUrl: cachedUrl)
                startAnnouncer(coordinatorUrl: cachedUrl, clusterToken: cachedToken)
            }
        }
    }
    
    // MARK: - Configuration
    
    func configure(role: ClusterRole, clusterToken: String?, coordinatorUrl: String?) async {
        self.role = role
        self.clusterToken = clusterToken
        self.coordinatorUrl = coordinatorUrl
        
        if role == .coordinator {
            startHealthChecks()
        } else {
            stopHealthChecks()
            peers.removeAll()
        }
        
        let currentPeers = Array(peers.values)
        await MainActor.run {
            ClusterStatus.shared.update(role: role, peers: currentPeers, coordinatorUrl: coordinatorUrl)
        }
        
        print("ClusterManager: Configured as \(role.rawValue)")
    }
    
    private func bootstrapPeersFromDirectory(_ directoryPeers: [ClusterPeerInfo], clusterToken: String) async {
        syncPeersFromDirectory(directoryPeers)
        guard !directoryPeers.isEmpty else { return }
        
        await withTaskGroup(of: Void.self) { group in
            for peer in directoryPeers {
                group.addTask {
                    await self.refreshPeerFromDirectory(peer, clusterToken: clusterToken)
                }
            }
        }
    }
    
    private func syncPeersFromDirectory(_ directoryPeers: [ClusterPeerInfo]) {
        let directoryIds = Set(directoryPeers.map(\.tunnelId))
        peers = peers.filter { directoryIds.contains($0.key) }
        
        for peer in directoryPeers {
            let existing = peers[peer.tunnelId]
            peers[peer.tunnelId] = PeerNode(
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
        
        Task {
            await self.publishPeerUpdate()
        }
    }
    
    private func refreshPeerFromDirectory(_ peer: ClusterPeerInfo, clusterToken: String) async {
        let client = PeerAPIClient(baseURL: peer.url, clusterToken: clusterToken)
        
        do {
            let systemStatus = try await client.systemStatus()
            let existing = peers[peer.tunnelId]
            let wasUnavailable = existing?.status != .online || (existing?.availableSlots ?? 0) == 0
            
            peers[peer.tunnelId] = PeerNode(
                id: peer.tunnelId,
                subdomain: peer.subdomain,
                name: peer.name,
                tunnelUrl: peer.url,
                status: .online,
                availableSlots: systemStatus.vms.available,
                runningTasks: systemStatus.agents.running,
                queuedTasks: systemStatus.agents.queued,
                lastSeen: Date(),
                providers: existing?.providers ?? []
            )
            await publishPeerUpdate()
            
            if wasUnavailable, systemStatus.vms.available > 0 {
                await MainActor.run {
                    NotificationCenter.default.post(name: .clusterPeerBecameAvailable, object: nil)
                }
            }
            
            let needsModelFetch = peers[peer.tunnelId]?.providers.isEmpty != false ||
                peers[peer.tunnelId]?.providers.allSatisfy { $0.modelIds.isEmpty } == true
            if needsModelFetch {
                await fetchPeerCapabilities(
                    peerId: peer.tunnelId,
                    baseURL: peer.url,
                    clusterToken: clusterToken
                )
            }
        } catch {
            let existing = peers[peer.tunnelId]
            peers[peer.tunnelId] = PeerNode(
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
            await publishPeerUpdate()
            print("ClusterManager: Failed to bootstrap peer \(peer.tunnelId): \(error)")
        }
    }
    
    private static func heartbeatDate(_ lastHeartbeat: Double) -> Date {
        Date(timeIntervalSince1970: lastHeartbeat / 1000)
    }
    
    // MARK: - Coordinator: Peer Management
    
    func registerPeer(_ announcement: PeerAnnouncement) async {
        let node = PeerNode(
            id: announcement.tunnelId,
            subdomain: announcement.subdomain,
            name: announcement.name,
            tunnelUrl: announcement.tunnelUrl,
            status: .online,
            availableSlots: announcement.availableSlots,
            runningTasks: announcement.runningTasks,
            queuedTasks: announcement.queuedTasks,
            lastSeen: Date(),
            providers: announcement.providers ?? []
        )
        peers[announcement.tunnelId] = node
        await publishPeerUpdate()
        print("ClusterManager: Registered peer \(announcement.tunnelId) (\(announcement.name ?? "unknown"))")
        
        if node.availableSlots > 0 {
            await MainActor.run {
                NotificationCenter.default.post(name: .clusterPeerBecameAvailable, object: nil)
            }
        }
        
        // Fetch full model lists if the announcement only carried provider names
        let needsModelFetch = node.providers.isEmpty || node.providers.allSatisfy { $0.modelIds.isEmpty }
        if needsModelFetch, let token = clusterToken {
            Task {
                await self.fetchPeerCapabilities(
                    peerId: announcement.tunnelId,
                    baseURL: announcement.tunnelUrl,
                    clusterToken: token
                )
            }
        }
    }
    
    /// Fetch provider/model capabilities from a peer via its API and cache them
    private func fetchPeerCapabilities(peerId: String, baseURL: String, clusterToken: String) async {
        let client = PeerAPIClient(baseURL: baseURL, clusterToken: clusterToken)
        do {
            let capabilities = try await client.fetchProviderCapabilities()
            guard var node = peers[peerId] else { return }
            node.providers = capabilities
            peers[peerId] = node
            await publishPeerUpdate()
            print("ClusterManager: Fetched \(capabilities.count) provider(s) from peer \(node.name ?? peerId)")
        } catch {
            print("ClusterManager: Failed to fetch capabilities from peer \(peerId): \(error)")
        }
    }
    
    func removePeer(tunnelId: String) async {
        peers.removeValue(forKey: tunnelId)
        await publishPeerUpdate()
        print("ClusterManager: Removed peer \(tunnelId)")
    }
    
    func updatePeerCapacity(_ announcement: PeerAnnouncement) async {
        guard var node = peers[announcement.tunnelId] else {
            await registerPeer(announcement)
            return
        }
        node.availableSlots = announcement.availableSlots
        node.runningTasks = announcement.runningTasks
        node.queuedTasks = announcement.queuedTasks
        node.status = .online
        node.lastSeen = Date()
        if let providers = announcement.providers {
            node.providers = providers
        }
        peers[announcement.tunnelId] = node
        await publishPeerUpdate()
    }
    
    func markPeerOffline(tunnelId: String) async {
        guard var node = peers[tunnelId] else { return }
        node.status = .offline
        peers[tunnelId] = node
        await publishPeerUpdate()
        print("ClusterManager: Marked peer \(tunnelId) as offline")
    }
    
    func markPeerUnreachable(tunnelId: String) async {
        guard var node = peers[tunnelId] else { return }
        node.status = .unreachable
        peers[tunnelId] = node
        await publishPeerUpdate()
        print("ClusterManager: Marked peer \(tunnelId) as unreachable")
    }
    
    // MARK: - Coordinator: Dispatch
    
    /// Atomically selects the best peer AND reserves a slot on it.
    /// This prevents concurrent callers from selecting the same peer before
    /// the slot count is decremented.
    func reserveBestAvailablePeer(
        providerName: String? = nil,
        modelId: String? = nil,
        excluding: Set<String> = []
    ) -> PeerNode? {
        guard let peer = bestAvailablePeerInternal(
            providerName: providerName, modelId: modelId, excluding: excluding
        ) else {
            return nil
        }
        reserveSlotInternal(peerId: peer.id)
        return peer
    }
    
    /// Release a previously reserved slot (used when dispatch fails).
    func releaseSlot(peerId: String) {
        guard var node = peers[peerId] else { return }
        node.availableSlots += 1
        peers[peerId] = node
    }
    
    // MARK: - Internal Dispatch Helpers
    
    private func bestAvailablePeerInternal(
        providerName: String? = nil,
        modelId: String? = nil,
        excluding: Set<String> = []
    ) -> PeerNode? {
        let online = peers.values.filter { peer in
            guard peer.status == .online && peer.availableSlots > 0 && !excluding.contains(peer.id) else {
                return false
            }
            if let providerName, let modelId {
                if peer.providers.isEmpty {
                    return true
                }
                return peer.hasProvider(name: providerName, modelId: modelId)
            }
            return true
        }
        guard !online.isEmpty else { return nil }
        
        let order = UserDefaults.standard.stringArray(forKey: Self.dispatchOrderKey) ?? []
        if !order.isEmpty {
            for tunnelId in order {
                if let peer = online.first(where: { $0.id == tunnelId }) {
                    return peer
                }
            }
        }
        
        return online.sorted { $0.availableSlots > $1.availableSlots }.first
    }
    
    private func reserveSlotInternal(peerId: String) {
        guard var node = peers[peerId] else { return }
        node.availableSlots = max(0, node.availableSlots - 1)
        peers[peerId] = node
    }
    
    func allOnlinePeers() -> [PeerNode] {
        peers.values.filter { $0.status == .online }
    }
    
    // MARK: - Dispatch Order
    
    nonisolated func getDispatchOrder() -> [String] {
        UserDefaults.standard.stringArray(forKey: Self.dispatchOrderKey) ?? []
    }
    
    nonisolated func setDispatchOrder(_ order: [String]) {
        UserDefaults.standard.set(order, forKey: Self.dispatchOrderKey)
    }
    
    // MARK: - Worker: Announcer
    
    private func startAnnouncer(coordinatorUrl: String, clusterToken: String) {
        announcer = ClusterAnnouncer(coordinatorUrl: coordinatorUrl, clusterToken: clusterToken)
        
        Task {
            await announcer?.announceCapacity()
        }
    }
    
    /// Called by the worker when its own task capacity changes
    func notifyCapacityChanged() {
        guard role == .worker else { return }
        Task {
            await announcer?.announceCapacity()
        }
    }
    
    /// Called by the worker when a task's status changes
    func notifyTaskStatusChanged(task: APITask) {
        guard role == .worker else { return }
        Task {
            await announcer?.announceTaskUpdate(task: task)
        }
    }
    
    /// Graceful shutdown: tell coordinator we're leaving
    func shutdown() async {
        stopHealthChecks()
        if role == .worker {
            await announcer?.announceDeparture()
        }
    }
    
    // MARK: - Health Checks
    
    private func startHealthChecks() {
        healthCheckTask?.cancel()
        healthCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.healthCheckInterval))
                guard !Task.isCancelled else { break }
                await self?.probeAllPeers()
            }
        }
    }
    
    private func stopHealthChecks() {
        healthCheckTask?.cancel()
        healthCheckTask = nil
    }
    
    private func probeAllPeers() async {
        let currentPeers = Array(peers.values)
        guard !currentPeers.isEmpty else { return }
        
        let results = await withTaskGroup(of: (String, Bool).self) { group in
            for peer in currentPeers {
                let url = peer.tunnelUrl
                group.addTask {
                    return (peer.id, await Self.probePeerHealth(url: url))
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
            guard var peer = peers[id] else { continue }
            if reachable && peer.status != .online {
                let wasOffline = peer.status == .offline
                peer.status = .online
                peer.lastSeen = Date()
                peers[id] = peer
                stateChanged = true
                print("ClusterManager: Health probe passed for \(peer.name ?? id), marking online")
                if wasOffline {
                    peersToRefreshCapabilities.append((id: id, url: peer.tunnelUrl))
                }
            } else if !reachable && peer.status == .online {
                peer.status = .offline
                peers[id] = peer
                stateChanged = true
                print("ClusterManager: Health probe failed for \(peer.name ?? id), marking offline")
            }
        }
        
        // Refresh capabilities for peers that just came back online
        if let token = clusterToken {
            for peer in peersToRefreshCapabilities {
                Task { await self.fetchPeerCapabilities(peerId: peer.id, baseURL: peer.url, clusterToken: token) }
            }
        }
        
        if stateChanged {
            await publishPeerUpdate()
            
            let anyPeerCameOnline = peersToRefreshCapabilities.contains { entry in
                peers[entry.id]?.availableSlots ?? 0 > 0
            }
            if anyPeerCameOnline {
                await MainActor.run {
                    NotificationCenter.default.post(name: .clusterPeerBecameAvailable, object: nil)
                }
            }
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
    
    private func publishPeerUpdate() async {
        let currentPeers = Array(peers.values)
        await MainActor.run {
            ClusterStatus.shared.updatePeers(currentPeers)
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let clusterCapacityChanged = Notification.Name("clusterCapacityChanged")
    static let clusterTaskStatusChanged = Notification.Name("clusterTaskStatusChanged")
    /// Posted when a peer with free slots appears or comes back online.
    /// The coordinator should check if local queued tasks can be offloaded.
    static let clusterPeerBecameAvailable = Notification.Name("clusterPeerBecameAvailable")
}
