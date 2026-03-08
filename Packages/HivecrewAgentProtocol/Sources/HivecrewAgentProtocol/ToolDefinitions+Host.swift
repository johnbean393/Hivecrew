//
//  ToolDefinitions+Host.swift
//  HivecrewAgentProtocol
//

import Foundation

public struct WebSearchParams: Codable, Sendable {
    public let query: String
    public let site: String?
    public let resultCount: Int?
    public let startDate: String?
    public let endDate: String?

    public init(query: String, site: String? = nil, resultCount: Int? = nil, startDate: String? = nil, endDate: String? = nil) {
        self.query = query
        self.site = site
        self.resultCount = resultCount
        self.startDate = startDate
        self.endDate = endDate
    }
}

public struct SearchResultItem: Codable, Sendable {
    public let url: String
    public let title: String
    public let snippet: String

    public init(url: String, title: String, snippet: String) {
        self.url = url
        self.title = title
        self.snippet = snippet
    }
}

public struct ReadWebpageContentParams: Codable, Sendable {
    public let url: String

    public init(url: String) {
        self.url = url
    }
}

public struct ExtractInfoFromWebpageParams: Codable, Sendable {
    public let url: String
    public let question: String

    public init(url: String, question: String) {
        self.url = url
        self.question = question
    }
}

public struct LocationResult: Codable, Sendable {
    public let location: String

    public init(location: String) {
        self.location = location
    }
}

public struct CreateTodoListParams: Codable, Sendable {
    public let title: String
    public let items: [String]?

    public init(title: String, items: [String]? = nil) {
        self.title = title
        self.items = items
    }
}

public struct AddTodoItemParams: Codable, Sendable {
    public let item: String

    public init(item: String) {
        self.item = item
    }
}

public struct FinishTodoItemParams: Codable, Sendable {
    public let index: Int

    public init(index: Int) {
        self.index = index
    }
}

public struct RequestUserInterventionParams: Codable, Sendable {
    public let message: String
    public let service: String?

    public init(message: String, service: String? = nil) {
        self.message = message
        self.service = service
    }
}

public struct GetLoginCredentialsParams: Codable, Sendable {
    public let service: String?

    public init(service: String? = nil) {
        self.service = service
    }
}

public struct GenerateImageParams: Codable, Sendable {
    public let prompt: String
    public let referenceImagePaths: [String]?
    public let aspectRatio: String?

    public init(prompt: String, referenceImagePaths: [String]? = nil, aspectRatio: String? = nil) {
        self.prompt = prompt
        self.referenceImagePaths = referenceImagePaths
        self.aspectRatio = aspectRatio
    }
}
