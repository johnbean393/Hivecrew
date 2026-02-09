//
//  ProvisioningRoutes.swift
//  HivecrewAPI
//
//  Routes for /api/v1/provisioning
//

import Foundation
import Hummingbird
import NIOCore
import HTTPTypes

/// Register provisioning routes
public struct ProvisioningRoutes: Sendable {
    let serviceProvider: APIServiceProvider
    
    public init(serviceProvider: APIServiceProvider) {
        self.serviceProvider = serviceProvider
    }
    
    public func register(with router: any RouterMethods<APIRequestContext>) {
        let provisioning = router.group("provisioning")
        
        // GET /provisioning - Get VM provisioning config (env vars and injected files)
        provisioning.get(use: getProvisioning)
    }
    
    // MARK: - Route Handlers
    
    @Sendable
    func getProvisioning(request: Request, context: APIRequestContext) async throws -> Response {
        let response = try await serviceProvider.getProvisioning()
        return try createJSONResponse(response)
    }
}
