//
//  ClusterManager.swift
//  Hivecrew
//
//  Central actor managing cluster membership, peer state, and dispatch decisions
//

import Combine
import Foundation
import HivecrewAPI
import HivecrewCore

// MARK: - Cluster Membership

enum ClusterRole: String, Sendable {
    case none
    case member
}

// MARK: - Observable Status

@MainActor
final class ClusterStatus: ObservableObject {
    static let shared = ClusterStatus()
    
    @Published var role: ClusterRole = .none
    @Published var peers: [PeerNode] = []
    
    private init() {}
    
    func update(role: ClusterRole, peers: [PeerNode] = []) {
        self.role = role
        self.peers = peers
    }
    
    func updatePeers(_ peers: [PeerNode]) {
        self.peers = peers
    }

    func displayName(forPeerId peerId: String?) -> String? {
        guard let peerId else { return nil }
        guard let peer = peers.first(where: { $0.id == peerId }) else { return peerId }
        return peer.name ?? peer.subdomain
    }
    
    func reset() {
        role = .none
        peers = []
    }
}

// MARK: - Cluster Manager

actor ClusterManager {
    static let shared = ClusterManager()
    
    private(set) var role: ClusterRole = .none
    private(set) var peers: [String: PeerNode] = [:]
    private(set) var clusterToken: String?
    
    private let apiClient = RemoteAccessAPIClient()
    private var capacityObserver: Any?
    private var healthCheckTask: Task<Void, Never>?
    private var peerProbeFailureCounts: [String: Int] = [:]
    
    private static let healthCheckInterval: TimeInterval = 10
    private static let peerOfflineThreshold = 3
    private static let dispatchOrderKey = "clusterDispatchOrder"
    private static let maxReportedPeerCount = 1_000_000
    
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
            await configure(role: .none, clusterToken: nil)
            return
        }
        
        do {
            var info = try await apiClient.getClusterInfo(sessionToken: sessionToken)
            
            if !info.hasCluster {
                info = try await apiClient.ensureCluster(sessionToken: sessionToken)
                guard info.hasCluster else {
                    await configure(role: .none, clusterToken: nil)
                    return
                }
            }
            
            guard let token = info.clusterToken else {
                await configure(role: .none, clusterToken: nil)
                return
            }
            
            let directoryPeers = filteredRemotePeers(from: info.peers)

            await configure(role: .member, clusterToken: token)
            RemoteAccessKeychain.storeClusterToken(token)
            await bootstrapPeersFromDirectory(directoryPeers, clusterToken: token)
        } catch {
            print("ClusterManager: Failed to get cluster info: \(error)")
            
            // Fall back to cached credentials
            if let cachedToken = RemoteAccessKeychain.retrieveClusterToken() {
                await configure(role: .member, clusterToken: cachedToken)
            }
        }
    }
    
    // MARK: - Configuration
    
    func configure(role: ClusterRole, clusterToken: String?) async {
        self.role = role
        self.clusterToken = clusterToken
        
        if role != .none {
            startHealthChecks()
        } else {
            stopHealthChecks()
            peers.removeAll()
        }
        
        let currentPeers = Array(peers.values)
        await MainActor.run {
            ClusterStatus.shared.update(role: role, peers: currentPeers)
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
        let remotePeers = directoryPeers.filter { !isLocalPeer(tunnelId: $0.tunnelId, subdomain: $0.subdomain, url: $0.url) }
        let directoryIds = Set(remotePeers.map(\.tunnelId))
        peers = peers.filter { directoryIds.contains($0.key) }
        
        for peer in remotePeers {
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
            let clusterStatus = try await client.getClusterStatus()
            let existing = peers[peer.tunnelId]
            let wasUnavailable = existing?.status != .online || (existing?.availableSlots ?? 0) == 0
            let availableSlots = Self.sanitizeReportedCount(clusterStatus.localAvailableSlots, label: "availableSlots", peerId: peer.tunnelId)
            let runningTasks = Self.sanitizeReportedCount(clusterStatus.localRunning, label: "runningTasks", peerId: peer.tunnelId)
            let queuedTasks = Self.sanitizeReportedCount(clusterStatus.localQueued, label: "queuedTasks", peerId: peer.tunnelId)
            
            peers[peer.tunnelId] = PeerNode(
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
            await publishPeerUpdate()
            
            if wasUnavailable, availableSlots > 0 {
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
    
    // MARK: - Peer Management
    
    func registerPeer(_ announcement: PeerAnnouncement) async {
        guard !isLocalPeer(
            tunnelId: announcement.tunnelId,
            subdomain: announcement.subdomain,
            url: announcement.tunnelUrl
        ) else {
            return
        }

        let availableSlots = Self.sanitizeReportedCount(announcement.availableSlots, label: "announcement availableSlots", peerId: announcement.tunnelId)
        let runningTasks = Self.sanitizeReportedCount(announcement.runningTasks, label: "announcement runningTasks", peerId: announcement.tunnelId)
        let queuedTasks = Self.sanitizeReportedCount(announcement.queuedTasks, label: "announcement queuedTasks", peerId: announcement.tunnelId)
        let node = PeerNode(
            id: announcement.tunnelId,
            subdomain: announcement.subdomain,
            name: announcement.name,
            tunnelUrl: announcement.tunnelUrl,
            status: .online,
            availableSlots: availableSlots,
            runningTasks: runningTasks,
            queuedTasks: queuedTasks,
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
        peerProbeFailureCounts.removeValue(forKey: tunnelId)
        peers.removeValue(forKey: tunnelId)
        await publishPeerUpdate()
        print("ClusterManager: Removed peer \(tunnelId)")
    }
    
    func updatePeerCapacity(_ announcement: PeerAnnouncement) async {
        guard var node = peers[announcement.tunnelId] else {
            await registerPeer(announcement)
            return
        }
        node.availableSlots = Self.sanitizeReportedCount(announcement.availableSlots, label: "capacity availableSlots", peerId: announcement.tunnelId)
        node.runningTasks = Self.sanitizeReportedCount(announcement.runningTasks, label: "capacity runningTasks", peerId: announcement.tunnelId)
        node.queuedTasks = Self.sanitizeReportedCount(announcement.queuedTasks, label: "capacity queuedTasks", peerId: announcement.tunnelId)
        node.status = .online
        node.lastSeen = Date()
        if let providers = announcement.providers {
            node.providers = providers
        }
        peers[announcement.tunnelId] = node
        await publishPeerUpdate()
    }

    private static func sanitizeReportedCount(_ value: Int, label: String, peerId: String) -> Int {
        if value < 0 {
            print("ClusterManager: Received negative \(label) from peer \(peerId); clamping to 0")
            return 0
        }
        if value > maxReportedPeerCount {
            print("ClusterManager: Received suspicious \(label)=\(value) from peer \(peerId); clamping to \(maxReportedPeerCount)")
            return maxReportedPeerCount
        }
        return value
    }
    
    func markPeerOffline(tunnelId: String) async {
        guard var node = peers[tunnelId] else { return }
        peerProbeFailureCounts[tunnelId] = Self.peerOfflineThreshold
        node.status = .offline
        peers[tunnelId] = node
        await publishPeerUpdate()
        await MainActor.run {
            NotificationCenter.default.post(name: .clusterPeerBecameUnavailable, object: tunnelId)
        }
        print("ClusterManager: Marked peer \(tunnelId) as offline")
    }
    
    func markPeerUnreachable(tunnelId: String) async {
        guard var node = peers[tunnelId] else { return }
        node.status = .unreachable
        peers[tunnelId] = node
        await publishPeerUpdate()
        print("ClusterManager: Marked peer \(tunnelId) as unreachable")
    }
    
    // MARK: - Dispatch
    
    /// Atomically selects the best peer AND reserves a slot on it.
    /// This prevents concurrent callers from selecting the same peer before
    /// the slot count is decremented.
    func reserveBestAvailablePeer(
        providerName: String? = nil,
        modelId: String? = nil,
        excluding: Set<String> = []
    ) async -> PeerNode? {
        if let providerName, let modelId {
            await refreshCapabilitiesForDispatch(
                providerName: providerName,
                modelId: modelId,
                excluding: excluding
            )
        }
        guard let peer = bestAvailablePeerInternal(
            providerName: providerName, modelId: modelId, excluding: excluding
        ) else {
            return nil
        }
        reserveSlotInternal(peerId: peer.id)
        return peer
    }

    func reserveSpecificPeer(
        peerId: String,
        providerName: String? = nil,
        modelId: String? = nil
    ) async -> PeerNode? {
        if let providerName, let modelId {
            await refreshCapabilitiesIfNeeded(
                peerId: peerId,
                providerName: providerName,
                modelId: modelId
            )
        }

        guard let peer = peers[peerId],
              peer.status == .online,
              peer.availableSlots > 0 else {
            return nil
        }

        if let providerName, let modelId,
           peer.capabilityMatch(providerName: providerName, modelId: modelId) != .supported {
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
        let order = UserDefaults.standard.stringArray(forKey: Self.dispatchOrderKey) ?? []
        return Self.selectBestPeer(
            from: Array(peers.values),
            preferredOrder: order,
            providerName: providerName,
            modelId: modelId,
            excluding: excluding
        )
    }
    
    private func reserveSlotInternal(peerId: String) {
        guard var node = peers[peerId] else { return }
        node.availableSlots = max(0, node.availableSlots - 1)
        peers[peerId] = node
    }
    
    func allOnlinePeers() -> [PeerNode] {
        peers.values.filter { $0.status == .online }
    }

    func peer(id: String) -> PeerNode? {
        peers[id]
    }

    func markPeerOnline(tunnelId: String) async {
        guard var node = peers[tunnelId] else { return }
        guard node.status != .online else { return }
        peerProbeFailureCounts[tunnelId] = 0
        let wasUnavailable = node.availableSlots > 0
        node.status = .online
        node.lastSeen = Date()
        peers[tunnelId] = node
        await publishPeerUpdate()
        if wasUnavailable {
            await MainActor.run {
                NotificationCenter.default.post(name: .clusterPeerBecameAvailable, object: nil)
            }
        }
    }
    
    // MARK: - Dispatch Order
    
    nonisolated func getDispatchOrder() -> [String] {
        UserDefaults.standard.stringArray(forKey: Self.dispatchOrderKey) ?? []
    }
    
    nonisolated func setDispatchOrder(_ order: [String]) {
        UserDefaults.standard.set(order, forKey: Self.dispatchOrderKey)
    }
    
    // MARK: - Mesh Updates

    /// Called when local task capacity changes.
    /// Every member broadcasts to known peers so they can make fresh dispatch decisions.
    func notifyCapacityChanged() {
        Task {
            await broadcastCapacityUpdate()
        }
    }
    
    /// Called by the executor when an owner-owned task's status changes.
    func notifyTaskStatusChanged(
        canonicalTaskId: String,
        workerTaskId: String,
        executionAttempt: Int,
        task: APITask
    ) {
        Task {
            guard let leaseContext = await self.currentLeaseContext(forWorkerTaskId: workerTaskId) else { return }
            await pushTaskUpdate(
                ownerNodeId: leaseContext.ownerNodeId,
                update: PeerTaskUpdate(
                    tunnelId: RemoteAccessKeychain.retrieveTunnelId() ?? "",
                    canonicalTaskId: canonicalTaskId,
                    ownerLeaseId: leaseContext.leaseId,
                    workerTaskId: workerTaskId,
                    executionAttempt: executionAttempt,
                    task: task
                )
            )

            let trigger: String? = {
                switch task.status {
                case .completed:                        return "completed"
                case .failed, .timedOut, .maxIterations, .planFailed: return "failed"
                case .planReview:                       return "planReady"
                case .writebackReview:                  return "writebackReady"
                default:                                return nil
                }
            }()

            if let trigger {
                await sendVoIPPush(
                    targetOwnerId: leaseContext.ownerNodeId,
                    trigger: trigger,
                    taskId: canonicalTaskId,
                    workerName: task.title,
                    summary: task.resultSummary ?? task.errorMessage ?? ""
                )
            }
        }
    }

    /// Called when a running agent posts a question that needs the user's input.
    func notifyTaskQuestionAsked(
        canonicalTaskId: String,
        workerTaskId: String,
        question: String
    ) {
        Task {
            guard let leaseContext = await self.currentLeaseContext(forWorkerTaskId: workerTaskId) else { return }
            guard let apiTask = await APIServerManager.shared.localTaskSnapshot(taskId: workerTaskId) else { return }

            await pushTaskUpdate(
                ownerNodeId: leaseContext.ownerNodeId,
                update: PeerTaskUpdate(
                    tunnelId: RemoteAccessKeychain.retrieveTunnelId() ?? "",
                    canonicalTaskId: canonicalTaskId,
                    ownerLeaseId: leaseContext.leaseId,
                    workerTaskId: workerTaskId,
                    executionAttempt: 0,
                    task: apiTask
                )
            )

            await sendVoIPPush(
                targetOwnerId: leaseContext.ownerNodeId,
                trigger: "question",
                taskId: canonicalTaskId,
                workerName: apiTask.title,
                summary: question
            )
        }
    }

    /// Called when a running agent requests permission for a dangerous action.
    func notifyTaskPermissionRequested(
        canonicalTaskId: String,
        workerTaskId: String,
        details: String
    ) {
        Task {
            guard let leaseContext = await self.currentLeaseContext(forWorkerTaskId: workerTaskId) else { return }
            guard let apiTask = await APIServerManager.shared.localTaskSnapshot(taskId: workerTaskId) else { return }

            await pushTaskUpdate(
                ownerNodeId: leaseContext.ownerNodeId,
                update: PeerTaskUpdate(
                    tunnelId: RemoteAccessKeychain.retrieveTunnelId() ?? "",
                    canonicalTaskId: canonicalTaskId,
                    ownerLeaseId: leaseContext.leaseId,
                    workerTaskId: workerTaskId,
                    executionAttempt: 0,
                    task: apiTask
                )
            )

            await sendVoIPPush(
                targetOwnerId: leaseContext.ownerNodeId,
                trigger: "permission",
                taskId: canonicalTaskId,
                workerName: apiTask.title,
                summary: details
            )
        }
    }
    
    /// Graceful shutdown: tell peers we're leaving
    func shutdown() async {
        stopHealthChecks()
        if role != .none {
            await broadcastDeparture()
        }
    }
    
    func handleSystemWillSleep() async {
        stopHealthChecks()
        if role != .none {
            await broadcastDeparture()
        }
    }
    
    func handleTunnelDidConnect() async {
        await initialize()
        await APIServerManager.shared.restartAndWaitIfEnabled()
        if role != .none {
            await broadcastCapacityUpdate()
        }
    }
    
    // MARK: - Health Checks
    
    private func startHealthChecks() {
        healthCheckTask?.cancel()
        healthCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.healthCheckInterval))
                guard !Task.isCancelled else { break }
                await self?.refreshPeersFromDirectoryIfNeeded()
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
                peerProbeFailureCounts[id] = 0
                let wasOffline = peer.status == .offline
                peer.status = .online
                peer.lastSeen = Date()
                peers[id] = peer
                stateChanged = true
                print("ClusterManager: Health probe passed for \(peer.name ?? id), marking online")
                if wasOffline {
                    peersToRefreshCapabilities.append((id: id, url: peer.tunnelUrl))
                }
            } else if !reachable {
                let failureCount = (peerProbeFailureCounts[id] ?? 0) + 1
                peerProbeFailureCounts[id] = failureCount

                if failureCount >= Self.peerOfflineThreshold, peer.status != .offline {
                    peer.status = .offline
                    peers[id] = peer
                    stateChanged = true
                    print("ClusterManager: Health probe failed for \(peer.name ?? id) \(failureCount)x, marking offline")
                    await MainActor.run {
                        NotificationCenter.default.post(name: .clusterPeerBecameUnavailable, object: id)
                    }
                } else if failureCount < Self.peerOfflineThreshold, peer.status == .online {
                    peer.status = .unreachable
                    peers[id] = peer
                    stateChanged = true
                    print("ClusterManager: Health probe failed for \(peer.name ?? id) \(failureCount)x, marking unreachable")
                }
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

    private func refreshPeersFromDirectoryIfNeeded() async {
        guard role != .none,
              let sessionToken = RemoteAccessKeychain.retrieveSessionToken() else {
            return
        }

        do {
            let info = try await apiClient.getClusterInfo(sessionToken: sessionToken)
            guard info.hasCluster, let token = info.clusterToken else { return }
            let directoryPeers = filteredRemotePeers(from: info.peers)

            self.clusterToken = token
            RemoteAccessKeychain.storeClusterToken(token)

            await bootstrapPeersFromDirectory(directoryPeers, clusterToken: token)
        } catch {
            print("ClusterManager: Failed to refresh peer directory: \(error)")
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

    private func refreshCapabilitiesForDispatch(
        providerName: String,
        modelId: String,
        excluding: Set<String>
    ) async {
        guard let token = clusterToken else { return }

        let unknownPeers = peers.values.filter { peer in
            guard peer.status == .online, peer.availableSlots > 0, !excluding.contains(peer.id) else {
                return false
            }
            return peer.capabilityMatch(providerName: providerName, modelId: modelId) == .unknown
        }
        guard !unknownPeers.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            for peer in unknownPeers {
                group.addTask {
                    await self.fetchPeerCapabilities(
                        peerId: peer.id,
                        baseURL: peer.tunnelUrl,
                        clusterToken: token
                    )
                }
            }
        }
    }

    private func refreshCapabilitiesIfNeeded(
        peerId: String,
        providerName: String,
        modelId: String
    ) async {
        guard let token = clusterToken,
              let peer = peers[peerId],
              peer.status == .online,
              peer.availableSlots > 0,
              peer.capabilityMatch(providerName: providerName, modelId: modelId) == .unknown else {
            return
        }

        await fetchPeerCapabilities(
            peerId: peer.id,
            baseURL: peer.tunnelUrl,
            clusterToken: token
        )
    }

    nonisolated static func selectBestPeer(
        from peers: [PeerNode],
        preferredOrder: [String],
        providerName: String? = nil,
        modelId: String? = nil,
        excluding: Set<String> = []
    ) -> PeerNode? {
        let candidates = peers.filter { peer in
            guard peer.status == .online, peer.availableSlots > 0, !excluding.contains(peer.id) else {
                return false
            }
            guard let providerName, let modelId else { return true }
            return peer.capabilityMatch(providerName: providerName, modelId: modelId) == .supported
        }
        guard !candidates.isEmpty else { return nil }

        if !preferredOrder.isEmpty {
            for tunnelId in preferredOrder {
                if let peer = candidates.first(where: { $0.id == tunnelId }) {
                    return peer
                }
            }
        }

        return candidates.sorted {
            if $0.availableSlots == $1.availableSlots {
                return $0.id < $1.id
            }
            return $0.availableSlots > $1.availableSlots
        }.first
    }

    @MainActor
    private func currentLeaseContext(forWorkerTaskId workerTaskId: String) -> (ownerNodeId: String, leaseId: String?)? {
        guard let task = APIServerManager.shared.taskServiceRef?.tasks.first(where: { $0.id == workerTaskId }),
              let ownerNodeId = task.clusterOwnerNodeId else {
            return nil
        }
        return (ownerNodeId: ownerNodeId, leaseId: task.clusterLeaseId)
    }

    private func broadcastCapacityUpdate() async {
        guard role != .none,
              let selfId = RemoteAccessKeychain.retrieveTunnelId(),
              let subdomain = RemoteAccessKeychain.retrieveSubdomain(),
              !selfId.isEmpty,
              !subdomain.isEmpty else {
            return
        }

        let capacity = await localCapacity()
        let providerNames = await localProviderNames()

        let announcement = PeerAnnouncement(
            tunnelId: selfId,
            subdomain: subdomain,
            name: Host.current().localizedName,
            tunnelUrl: "https://\(subdomain).hivecrew.org",
            availableSlots: capacity.available,
            runningTasks: capacity.running,
            queuedTasks: capacity.queued,
            providers: providerNames.map {
                PeerProviderSummary(providerName: $0, modelIds: [])
            }
        )

        let currentPeers = peers.values.filter {
            !self.isLocalPeer(tunnelId: $0.id, subdomain: $0.subdomain, url: $0.tunnelUrl)
        }
        await withTaskGroup(of: Void.self) { group in
            for peer in currentPeers {
                group.addTask {
                    await self.postClusterPayload(
                        announcement,
                        to: "\(peer.tunnelUrl)/api/v1/cluster/announce"
                    )
                }
            }
        }
    }

    private func broadcastDeparture() async {
        guard let selfId = RemoteAccessKeychain.retrieveTunnelId(), !selfId.isEmpty else { return }
        let departure = PeerDeparture(tunnelId: selfId)
        let currentPeers = peers.values.filter {
            !self.isLocalPeer(tunnelId: $0.id, subdomain: $0.subdomain, url: $0.tunnelUrl)
        }
        await withTaskGroup(of: Void.self) { group in
            for peer in currentPeers {
                group.addTask {
                    await self.postClusterPayload(
                        departure,
                        to: "\(peer.tunnelUrl)/api/v1/cluster/depart"
                    )
                }
            }
        }
    }

    private func pushTaskUpdate(ownerNodeId: String, update: PeerTaskUpdate) async {
        guard let ownerPeer = peers[ownerNodeId] else { return }
        await postClusterPayload(update, to: "\(ownerPeer.tunnelUrl)/api/v1/cluster/task-update")
    }

    private func sendVoIPPush(
        targetOwnerId: String,
        trigger: String,
        taskId: String,
        workerName: String,
        summary: String
    ) async {
        guard let sessionToken = RemoteAccessKeychain.retrieveSessionToken() else { return }
        let peerId = RemoteAccessKeychain.retrieveTunnelId() ?? ""
        let payload = VoIPPushPayload(
            trigger: trigger,
            taskId: taskId,
            workerName: workerName,
            summary: String(summary.prefix(500)),
            peerId: peerId
        )
        do {
            try await apiClient.sendVoIPPush(
                sessionToken: sessionToken,
                targetOwnerId: targetOwnerId,
                payload: payload
            )
        } catch {
            print("[ClusterManager] VoIP push failed for \(trigger): \(error.localizedDescription)")
        }
    }

    @MainActor
    private func localCapacity() -> (available: Int, running: Int, queued: Int) {
        let maxConcurrent = VMConcurrencyPolicy.effectiveMaxConcurrentVMs()
        guard let taskService = APIServerManager.shared.taskServiceRef else {
            return (maxConcurrent, 0, 0)
        }

        let running = taskService.runningAgents.count
        let queued = taskService.tasks.filter {
            !$0.isInternalClusterExecution && $0.status == .queued
        }.count
        return (max(0, maxConcurrent - running), running, queued)
    }

    @MainActor
    private func localProviderNames() -> [String] {
        APIServerManager.shared.localProviderNames()
    }

    private func postClusterPayload<B: Encodable>(_ body: B, to urlString: String) async {
        guard let token = clusterToken,
              let url = URL(string: urlString) else { return }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
            _ = try await URLSession.shared.data(for: request)
        } catch {
            print("ClusterManager: Failed posting cluster payload to \(urlString): \(error)")
        }
    }

    private func filteredRemotePeers(from peers: [ClusterPeerInfo]) -> [ClusterPeerInfo] {
        peers.filter { !isLocalPeer(tunnelId: $0.tunnelId, subdomain: $0.subdomain, url: $0.url) }
    }

    private func isLocalPeer(tunnelId: String, subdomain: String?, url: String) -> Bool {
        if let localTunnelId = RemoteAccessKeychain.retrieveTunnelId(),
           !localTunnelId.isEmpty,
           tunnelId == localTunnelId {
            return true
        }

        if let localSubdomain = RemoteAccessKeychain.retrieveSubdomain(),
           !localSubdomain.isEmpty,
           subdomain?.caseInsensitiveCompare(localSubdomain) == .orderedSame {
            return true
        }

        guard let localHost = Self.tunnelHost(subdomain: RemoteAccessKeychain.retrieveSubdomain()) else {
            return false
        }
        return Self.normalizedTunnelHost(from: url) == localHost
    }

    private static func normalizedTunnelHost(from urlString: String) -> String? {
        if let host = URL(string: urlString)?.host?.lowercased() {
            return host
        }
        return urlString
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "https://", with: "", options: [.caseInsensitive])
            .replacingOccurrences(of: "http://", with: "", options: [.caseInsensitive])
            .lowercased()
    }

    private static func tunnelHost(subdomain: String?) -> String? {
        guard let subdomain, !subdomain.isEmpty else { return nil }
        return "\(subdomain).hivecrew.org".lowercased()
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let clusterCapacityChanged = Notification.Name("clusterCapacityChanged")
    static let clusterTaskStatusChanged = Notification.Name("clusterTaskStatusChanged")
    /// Posted when a peer with free slots appears or comes back online.
    /// Local queue draining should re-check whether work can be offloaded.
    static let clusterPeerBecameAvailable = Notification.Name("clusterPeerBecameAvailable")
    static let clusterPeerBecameUnavailable = Notification.Name("clusterPeerBecameUnavailable")
}
