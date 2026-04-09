//
//  ClusterRoutes.swift
//  HivecrewAPI
//
//  Routes for /api/v1/cluster (peer updates, remote execution, and mesh status)
//

import Foundation
import Hummingbird
import HivecrewShared
import Logging
import NIOCore

public struct ClusterRoutes: Sendable {
    let clusterServiceProvider: ClusterServiceProvider
    let fileStorage: TaskFileStorage
    let maxFileSize: Int
    let maxTotalUploadSize: Int
    private let logger = Logger(label: "com.pattonium.api.cluster")
    
    public init(
        clusterServiceProvider: ClusterServiceProvider,
        fileStorage: TaskFileStorage,
        maxFileSize: Int = 100 * 1024 * 1024,
        maxTotalUploadSize: Int = 500 * 1024 * 1024
    ) {
        self.clusterServiceProvider = clusterServiceProvider
        self.fileStorage = fileStorage
        self.maxFileSize = maxFileSize
        self.maxTotalUploadSize = maxTotalUploadSize
    }
    
    public func register(with router: any RouterMethods<APIRequestContext>) {
        let cluster = router.group("cluster")
        
        // Peer/member → peer/member (cluster-token auth)
        cluster.post("announce", use: handleAnnounce)
        cluster.post("task-update", use: handleTaskUpdate)
        cluster.post("depart", use: handleDepart)
        cluster.post("execute-now", use: handleExecuteNow)
        cluster.post("stage-inputs", use: handleStageInputs)
        
        // Web UI → local mesh member (normal auth: API key / session cookie)
        cluster.get("status", use: getClusterStatus)
        cluster.get("peers", use: getClusterPeers)
    }
    
    // MARK: - Peer Updates And Execution
    
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
    func handleExecuteNow(request: Request, context: APIRequestContext) async throws -> Response {
        let executeNowRequest = try await request.decode(as: ClusterExecuteNowRequest.self, context: context)
        let response = try await clusterServiceProvider.executeNow(executeNowRequest)
        return try createJSONResponse(response)
    }
    
    @Sendable
    func handleDepart(request: Request, context: APIRequestContext) async throws -> Response {
        let departure = try await request.decode(as: PeerDeparture.self, context: context)
        try await clusterServiceProvider.handleDeparture(tunnelId: departure.tunnelId)
        logger.info("Peer departed: \(departure.tunnelId)")
        return try createJSONResponse(["status": "ok"])
    }

    @Sendable
    func handleStageInputs(request: Request, context: APIRequestContext) async throws -> Response {
        let contentType = request.headers[.contentType] ?? ""
        guard contentType.contains("multipart/form-data") else {
            throw APIError.badRequest("Expected multipart/form-data")
        }

        let bodyData = try await request.body.collect(upTo: maxTotalUploadSize)
        let boundary = try extractMultipartBoundary(from: request)
        let parts = parseMultipartData(data: Data(buffer: bodyData), boundary: boundary)

        var stagingId: String?
        var stagedFilePaths: [String] = []

        for part in parts {
            guard let name = part.name else { continue }
            if name == "stagingId" {
                stagingId = String(data: part.data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else if name == "files" {
                let effectiveStagingId = stagingId ?? UUID().uuidString
                let filename = part.filename ?? "file_\(stagedFilePaths.count)"
                if part.data.count > maxFileSize {
                    throw APIError.payloadTooLarge("File '\(filename)' exceeds maximum size")
                }
                let savedURL = try await fileStorage.saveUploadedFile(
                    data: part.data,
                    filename: filename,
                    taskId: "cluster-stage-\(effectiveStagingId)"
                )
                stagedFilePaths.append(savedURL.path)
            }
        }

        return try createJSONResponse(ClusterStageInputFilesResponse(stagedFilePaths: stagedFilePaths))
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
