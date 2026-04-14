//
//  APIContext.swift
//  HivecrewAPI
//
//  Hummingbird request context for API routes
//

import Foundation
import Hummingbird
import HivecrewAPIModels

// MARK: - Request Context

/// Hummingbird request context used by all API routes.
public struct APIRequestContext: RequestContext {
    public var coreContext: CoreRequestContextStorage
    
    public init(source: Source) {
        self.coreContext = .init(source: source)
    }
}
