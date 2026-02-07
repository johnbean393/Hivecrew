//
//  TemplateRoutes.swift
//  HivecrewAPI
//
//  Routes for /api/v1/templates
//

import Foundation
import Hummingbird
import NIOCore
import HTTPTypes

/// Register template routes
public struct TemplateRoutes: Sendable {
    let serviceProvider: APIServiceProvider
    
    public init(serviceProvider: APIServiceProvider) {
        self.serviceProvider = serviceProvider
    }
    
    public func register(with router: any RouterMethods<APIRequestContext>) {
        let templates = router.group("templates")
        
        // GET /templates - List templates
        templates.get(use: listTemplates)
        
        // GET /templates/:id - Get template
        templates.get(":id", use: getTemplate)
    }
    
    // MARK: - Route Handlers
    
    @Sendable
    func listTemplates(request: Request, context: APIRequestContext) async throws -> Response {
        let response = try await serviceProvider.getTemplates()
        return try createJSONResponse(response)
    }
    
    @Sendable
    func getTemplate(request: Request, context: APIRequestContext) async throws -> Response {
        guard let templateId = context.parameters.get("id") else {
            throw APIError.badRequest("Missing template ID")
        }
        
        let template = try await serviceProvider.getTemplate(id: templateId)
        return try createJSONResponse(template)
    }
    
}
