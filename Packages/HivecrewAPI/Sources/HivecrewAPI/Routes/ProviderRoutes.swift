//
//  ProviderRoutes.swift
//  HivecrewAPI
//
//  Routes for /api/v1/providers
//

import Foundation
import Hummingbird
import NIOCore
import HTTPTypes

/// Register provider routes
public struct ProviderRoutes: Sendable {
    let serviceProvider: APIServiceProvider
    
    public init(serviceProvider: APIServiceProvider) {
        self.serviceProvider = serviceProvider
    }
    
    public func register(with router: any RouterMethods<APIRequestContext>) {
        let providers = router.group("providers")
        
        // GET /providers - List providers
        providers.get(use: listProviders)
        
        // GET /providers/:id - Get provider
        providers.get(":id", use: getProvider)
        
        // GET /providers/:id/models - List models
        providers.get(":id/models", use: listModels)
    }
    
    // MARK: - Route Handlers
    
    @Sendable
    func listProviders(request: Request, context: APIRequestContext) async throws -> Response {
        let response = try await serviceProvider.getProviders()
        return try createJSONResponse(response)
    }
    
    @Sendable
    func getProvider(request: Request, context: APIRequestContext) async throws -> Response {
        guard let providerId = context.parameters.get("id") else {
            throw APIError.badRequest("Missing provider ID")
        }
        
        let provider = try await serviceProvider.getProvider(id: providerId)
        return try createJSONResponse(provider)
    }
    
    @Sendable
    func listModels(request: Request, context: APIRequestContext) async throws -> Response {
        guard let providerId = context.parameters.get("id") else {
            throw APIError.badRequest("Missing provider ID")
        }
        
        let response = try await serviceProvider.getProviderModels(id: providerId)
        return try createJSONResponse(response)
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
