//
//  APITemplate.swift
//  HivecrewAPI
//
//  Template models for API responses
//

import Foundation

/// Template summary for list responses
public struct APITemplateSummary: Codable, Sendable {
    public let id: String
    public let name: String
    public let description: String?
    public let isDefault: Bool
    public let createdAt: Date?
    public let diskSizeGB: Int?
    public let cpuCount: Int?
    public let memoryGB: Int?
    
    public init(
        id: String,
        name: String,
        description: String? = nil,
        isDefault: Bool,
        createdAt: Date? = nil,
        diskSizeGB: Int? = nil,
        cpuCount: Int? = nil,
        memoryGB: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.isDefault = isDefault
        self.createdAt = createdAt
        self.diskSizeGB = diskSizeGB
        self.cpuCount = cpuCount
        self.memoryGB = memoryGB
    }
}

/// Template details for GET /templates/:id
public struct APITemplate: Codable, Sendable {
    public let id: String
    public let name: String
    public let description: String?
    public let isDefault: Bool
    public let createdAt: Date?
    public let diskSizeGB: Int?
    public let cpuCount: Int?
    public let memoryGB: Int?
    public let macOSVersion: String?
    public let path: String?
    
    public init(
        id: String,
        name: String,
        description: String? = nil,
        isDefault: Bool,
        createdAt: Date? = nil,
        diskSizeGB: Int? = nil,
        cpuCount: Int? = nil,
        memoryGB: Int? = nil,
        macOSVersion: String? = nil,
        path: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.isDefault = isDefault
        self.createdAt = createdAt
        self.diskSizeGB = diskSizeGB
        self.cpuCount = cpuCount
        self.memoryGB = memoryGB
        self.macOSVersion = macOSVersion
        self.path = path
    }
}

/// Response for GET /templates
public struct APITemplateListResponse: Codable, Sendable {
    public let templates: [APITemplateSummary]
    public let defaultTemplateId: String?
    
    public init(templates: [APITemplateSummary], defaultTemplateId: String? = nil) {
        self.templates = templates
        self.defaultTemplateId = defaultTemplateId
    }
}
