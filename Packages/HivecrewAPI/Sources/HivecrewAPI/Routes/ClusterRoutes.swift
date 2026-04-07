//
//  ClusterRoutes.swift
//  HivecrewAPI
//
//  Routes for /api/v1/cluster (peer announcements and cluster status)
//

import Foundation
import Hummingbird
import Logging
import NIOCore

public struct ClusterRoutes: Sendable {
    let clusterServiceProvider: ClusterServiceProvider
    private let logger = Logger(label: "com.pattonium.api.cluster")
    
    public init(clusterServiceProvider: ClusterServiceProvider) {
        self.clusterServiceProvider = clusterServiceProvider
    }
    
    public func register(with router: any RouterMethods<APIRequestContext>) {
        let cluster = router.group("cluster")
        
        // Worker → Coordinator (cluster-token auth)
        cluster.post("announce", use: handleAnnounce)
        cluster.post("task-update", use: handleTaskUpdate)
        cluster.post("depart", use: handleDepart)
        
        // Web UI → Coordinator (normal auth: API key / session cookie)
        cluster.get("status", use: getClusterStatus)
        cluster.get("peers", use: getClusterPeers)
    }
    
    // MARK: - Worker → Coordinator
    
    @Sendable
    func handleAnnounce(request: Request, context: APIRequestContext) async throws -> Response {
        let announcement = try await request.decode(as: PeerAnnouncement.self, context: context)
        try await clusterServiceProvider.handleAnnouncement(announcement)
        logger.info("Peer announced: \(announcement.tunnelId) (slots: \(announcement.availableSlots))")
        return try createJSONResponse(["status": "ok"])
    }
    
    @Sendable
    func handleTaskUpdate(request: Request, context: APIRequestContext) async throws -> Response {
        let update = try await request.decode(as: PeerTaskUpdate.self, context: context)
        try await clusterServiceProvider.handleTaskUpdate(update)
        return try createJSONResponse(["status": "ok"])
    }
    
    @Sendable
    func handleDepart(request: Request, context: APIRequestContext) async throws -> Response {
        let departure = try await request.decode(as: PeerDeparture.self, context: context)
        try await clusterServiceProvider.handleDeparture(tunnelId: departure.tunnelId)
        logger.info("Peer departed: \(departure.tunnelId)")
        return try createJSONResponse(["status": "ok"])
    }
    
    // MARK: - Web UI
    
    @Sendable
    func getClusterStatus(request: Request, context: APIRequestContext) async throws -> Response {
        let status = try await clusterServiceProvider.getClusterStatus()
        return try createJSONResponse(status)
    }
    
    @Sendable
    func getClusterPeers(request: Request, context: APIRequestContext) async throws -> Response {
        let peers = try await clusterServiceProvider.getClusterPeers()
        return try createJSONResponse(peers)
    }
    
    // MARK: - Helpers
    
    private func createJSONResponse<T: Encodable>(_ value: T) throws -> Response {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(data: data))
        )
    }
}
