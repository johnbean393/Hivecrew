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

public struct ListLocalEntriesParams: Codable, Sendable {
    public let path: String

    public init(path: String) {
        self.path = path
    }
}

public struct ImportLocalFileParams: Codable, Sendable {
    public let sourcePath: String?
    public let destinationPath: String?
    public let sourcePaths: [String]?
    public let destinationDirectory: String?

    public init(
        sourcePath: String? = nil,
        destinationPath: String? = nil,
        sourcePaths: [String]? = nil,
        destinationDirectory: String? = nil
    ) {
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.sourcePaths = sourcePaths
        self.destinationDirectory = destinationDirectory
    }
}

public struct StageWritebackCopyParams: Codable, Sendable {
    public let sourcePath: String?
    public let destinationPath: String?
    public let sourcePaths: [String]?
    public let destinationDirectory: String?
    public let deleteOriginalLocalPaths: [String]?

    public init(
        sourcePath: String? = nil,
        destinationPath: String? = nil,
        sourcePaths: [String]? = nil,
        destinationDirectory: String? = nil,
        deleteOriginalLocalPaths: [String]? = nil
    ) {
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.sourcePaths = sourcePaths
        self.destinationDirectory = destinationDirectory
        self.deleteOriginalLocalPaths = deleteOriginalLocalPaths
    }
}

public struct StageWritebackMoveParams: Codable, Sendable {
    public let sourcePath: String
    public let destinationPath: String
    public let deleteOriginalLocalPaths: [String]?

    public init(sourcePath: String, destinationPath: String, deleteOriginalLocalPaths: [String]? = nil) {
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.deleteOriginalLocalPaths = deleteOriginalLocalPaths
    }
}

public struct StageAttachedFileUpdateParams: Codable, Sendable {
    public let sourcePath: String
    public let attachmentPath: String?

    public init(sourcePath: String, attachmentPath: String? = nil) {
        self.sourcePath = sourcePath
        self.attachmentPath = attachmentPath
    }
}
