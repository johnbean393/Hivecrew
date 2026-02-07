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
    
}
