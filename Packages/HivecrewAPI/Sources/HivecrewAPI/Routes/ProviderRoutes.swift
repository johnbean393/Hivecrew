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

        // POST /providers - Create provider
        providers.post(use: createProvider)
        
        // GET /providers/:id - Get provider
        providers.get(":id", use: getProvider)

        // PATCH /providers/:id - Update provider
        providers.patch(":id", use: updateProvider)

        // DELETE /providers/:id - Delete provider
        providers.delete(":id", use: deleteProvider)
        
        // GET /providers/:id/models - List models
        providers.get(":id/models", use: listModels)

        // POST /providers/:id/auth/start - Start provider auth flow
        providers.post(":id/auth/start", use: startAuth)

        // GET /providers/:id/auth/status - Poll provider auth status
        providers.get(":id/auth/status", use: authStatus)

        // POST /providers/:id/auth/logout - Logout provider auth
        providers.post(":id/auth/logout", use: logoutAuth)
    }
    
    // MARK: - Route Handlers
    
    @Sendable
    func listProviders(request: Request, context: APIRequestContext) async throws -> Response {
        let response = try await serviceProvider.getProviders()
        return try createJSONResponse(response)
    }

    @Sendable
    func createProvider(request: Request, context: APIRequestContext) async throws -> Response {
        let body = try await request.body.collect(upTo: 128 * 1024)
        let createRequest = try makeISO8601Decoder().decode(APICreateProviderRequest.self, from: body)
        let provider = try await serviceProvider.createProvider(request: createRequest)
        return try createJSONResponse(provider, status: .created)
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
    func updateProvider(request: Request, context: APIRequestContext) async throws -> Response {
        guard let providerId = context.parameters.get("id") else {
            throw APIError.badRequest("Missing provider ID")
        }
        let body = try await request.body.collect(upTo: 128 * 1024)
        let updateRequest = try makeISO8601Decoder().decode(APIUpdateProviderRequest.self, from: body)
        let provider = try await serviceProvider.updateProvider(id: providerId, request: updateRequest)
        return try createJSONResponse(provider)
    }

    @Sendable
    func deleteProvider(request: Request, context: APIRequestContext) async throws -> Response {
        guard let providerId = context.parameters.get("id") else {
            throw APIError.badRequest("Missing provider ID")
        }
        try await serviceProvider.deleteProvider(id: providerId)
        return Response(status: .noContent)
    }
    
    @Sendable
    func listModels(request: Request, context: APIRequestContext) async throws -> Response {
        guard let providerId = context.parameters.get("id") else {
            throw APIError.badRequest("Missing provider ID")
        }
        
        let response = try await serviceProvider.getProviderModels(id: providerId)
        return try createJSONResponse(response)
    }

    @Sendable
    func startAuth(request: Request, context: APIRequestContext) async throws -> Response {
        guard let providerId = context.parameters.get("id") else {
            throw APIError.badRequest("Missing provider ID")
        }
        let response = try await serviceProvider.startProviderAuth(id: providerId)
        return try createJSONResponse(response)
    }

    @Sendable
    func authStatus(request: Request, context: APIRequestContext) async throws -> Response {
        guard let providerId = context.parameters.get("id") else {
            throw APIError.badRequest("Missing provider ID")
        }
        let response = try await serviceProvider.getProviderAuthStatus(id: providerId)
        return try createJSONResponse(response)
    }

    @Sendable
    func logoutAuth(request: Request, context: APIRequestContext) async throws -> Response {
        guard let providerId = context.parameters.get("id") else {
            throw APIError.badRequest("Missing provider ID")
        }
        let response = try await serviceProvider.logoutProviderAuth(id: providerId)
        return try createJSONResponse(response)
    }
    
}
