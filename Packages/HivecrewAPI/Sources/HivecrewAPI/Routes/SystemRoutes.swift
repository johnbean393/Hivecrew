//
//  SystemRoutes.swift
//  HivecrewAPI
//
//  Routes for /api/v1/system
//

import Foundation
import Hummingbird
import NIOCore
import HTTPTypes

/// Register system routes
public struct SystemRoutes: Sendable {
    let serviceProvider: APIServiceProvider
    
    public init(serviceProvider: APIServiceProvider) {
        self.serviceProvider = serviceProvider
    }
    
    public func register(with router: any RouterMethods<APIRequestContext>) {
        let system = router.group("system")
        
        // GET /system/status - Get system status
        system.get("status", use: getStatus)
        
        // GET /system/config - Get system configuration
        system.get("config", use: getConfig)
    }
    
    // MARK: - Route Handlers
    
    @Sendable
    func getStatus(request: Request, context: APIRequestContext) async throws -> Response {
        let status = try await serviceProvider.getSystemStatus()
        return try createJSONResponse(status)
    }
    
    @Sendable
    func getConfig(request: Request, context: APIRequestContext) async throws -> Response {
        let config = try await serviceProvider.getSystemConfig()
        return try createJSONResponse(config)
    }
    
    // MARK: - Helpers
    
    private func createJSONResponse<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) throws -> Response {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        
        return Response(
            status: status,
            headers: headers,
            body: .init(byteBuffer: ByteBuffer(data: data))
        )
    }
}
