//
//  APISkill.swift
//  HivecrewAPI
//
//  Skill models for API responses
//

import Foundation

/// Skill summary for list responses
public struct APISkill: Codable, Sendable {
    public let name: String
    public let description: String
    public let isEnabled: Bool
    
    public init(
        name: String,
        description: String,
        isEnabled: Bool
    ) {
        self.name = name
        self.description = description
        self.isEnabled = isEnabled
    }
}

/// Response for GET /skills
public struct APISkillListResponse: Codable, Sendable {
    public let skills: [APISkill]
    
    public init(skills: [APISkill]) {
        self.skills = skills
    }
}
