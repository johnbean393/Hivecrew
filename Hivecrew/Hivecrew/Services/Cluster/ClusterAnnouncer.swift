//
//  ClusterAnnouncer.swift
//  Hivecrew
//
//  Runs on worker machines. Pushes capacity and task status updates to the coordinator.
//

import Foundation
import HivecrewAPI

actor ClusterAnnouncer {
    private let coordinatorUrl: String
    private let clusterToken: String
    private let session: URLSession
    
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    
    init(coordinatorUrl: String, clusterToken: String) {
        self.coordinatorUrl = coordinatorUrl
        self.clusterToken = clusterToken
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        self.session = URLSession(configuration: config)
    }
    
    // MARK: - Announcements
    
    /// Push current capacity to the coordinator.
    /// Reads local tunnel info and task counts to build the announcement.
    func announceCapacity() async {
        guard let tunnelId = RemoteAccessKeychain.retrieveTunnelId(),
              let subdomain = RemoteAccessKeychain.retrieveSubdomain() else {
            print("ClusterAnnouncer: No tunnel credentials, skipping announcement")
            return
        }
        
        let machineName = Host.current().localizedName
        let tunnelUrl = "https://\(subdomain).hivecrew.org"
        
        let (available, running, queued) = await readLocalCapacity()
        let providerNames = await readLocalProviderNames()
        
        let providers = providerNames.map { PeerProviderSummary(providerName: $0, modelIds: []) }
        
        let announcement = PeerAnnouncement(
            tunnelId: tunnelId,
            subdomain: subdomain,
            name: machineName,
            tunnelUrl: tunnelUrl,
            availableSlots: available,
            runningTasks: running,
            queuedTasks: queued,
            providers: providers
        )
        
        do {
            try await post("/api/v1/cluster/announce", body: announcement)
            print("ClusterAnnouncer: Announced capacity (available: \(available), running: \(running), providers: \(providerNames.count))")
        } catch {
            print("ClusterAnnouncer: Failed to announce capacity: \(error)")
        }
    }
    
    /// Push a task status update to the coordinator
    func announceTaskUpdate(
        canonicalTaskId: String,
        workerTaskId: String,
        executionAttempt: Int,
        task: APITask
    ) async {
        guard let tunnelId = RemoteAccessKeychain.retrieveTunnelId() else { return }
        
        let update = PeerTaskUpdate(
            tunnelId: tunnelId,
            canonicalTaskId: canonicalTaskId,
            workerTaskId: workerTaskId,
            executionAttempt: executionAttempt,
            task: task
        )
        
        do {
            try await post("/api/v1/cluster/task-update", body: update)
        } catch {
            print("ClusterAnnouncer: Failed to push task update: \(error)")
        }
    }
    
    /// Tell the coordinator we are going offline
    func announceDeparture() async {
        guard let tunnelId = RemoteAccessKeychain.retrieveTunnelId() else { return }
        
        let departure = PeerDeparture(tunnelId: tunnelId)
        
        do {
            try await post("/api/v1/cluster/depart", body: departure)
            print("ClusterAnnouncer: Departure announced")
        } catch {
            print("ClusterAnnouncer: Failed to announce departure: \(error)")
        }
    }
    
    // MARK: - Private
    
    @MainActor
    private func readLocalCapacity() -> (available: Int, running: Int, queued: Int) {
        let maxConcurrent = VMConcurrencyPolicy.effectiveMaxConcurrentVMs()
        
        guard let taskService = APIServerManager.shared.taskServiceRef else {
            return (maxConcurrent, 0, 0)
        }
        
        let running = taskService.runningAgents.count
        let queued = taskService.tasks.filter { $0.status == .queued }.count
        let available = max(0, maxConcurrent - running)
        return (available, running, queued)
    }
    
    @MainActor
    private func readLocalProviderNames() -> [String] {
        APIServerManager.shared.localProviderNames()
    }
    
    private func post<B: Encodable>(_ path: String, body: B) async throws {
        guard let url = URL(string: "\(coordinatorUrl)\(path)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(clusterToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder.encode(body)
        
        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw PeerAPIError.httpError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }
}
