//
//  SkillRoutes.swift
//  HivecrewAPI
//
//  Routes for /api/v1/skills
//

import Foundation
import Hummingbird
import NIOCore
import HTTPTypes

/// Register skill routes
public struct SkillRoutes: Sendable {
    let serviceProvider: APIServiceProvider
    
    public init(serviceProvider: APIServiceProvider) {
        self.serviceProvider = serviceProvider
    }
    
    public func register(with router: any RouterMethods<APIRequestContext>) {
        let skills = router.group("skills")
        
        // GET /skills - List skills
        skills.get(use: listSkills)
    }
    
    // MARK: - Route Handlers
    
    @Sendable
    func listSkills(request: Request, context: APIRequestContext) async throws -> Response {
        let skills = try await serviceProvider.getSkills()
        let response = APISkillListResponse(skills: skills)
        return try createJSONResponse(response)
    }
}
