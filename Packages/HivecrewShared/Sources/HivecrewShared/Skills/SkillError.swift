//
//  SkillError.swift
//  HivecrewShared
//
//  Error types for skill operations
//

import Foundation

/// Errors that can occur during skill operations
public enum SkillError: Error, LocalizedError {
    /// SKILL.md file is missing from directory
    case missingSkillFile
    
    /// Invalid SKILL.md format (missing frontmatter, etc.)
    case invalidFormat(String)
    
    /// Skill name is invalid (doesn't meet spec requirements)
    case invalidName(String)
    
    /// Required description field is missing or empty
    case missingDescription
    
    /// A skill with this name already exists
    case skillAlreadyExists(String)
    
    /// Skill was not found
    case skillNotFound(String)
    
    /// Invalid file provided (not a SKILL.md file)
    case invalidFile(String)
    
    /// Failed to parse YAML frontmatter
    case yamlParseError(String)
    
    /// Network error during GitHub import
    case networkError(String)
    
    /// GitHub skill not found
    case githubSkillNotFound(String)
    
    /// Invalid GitHub URL format
    case invalidGitHubURL(String)
    
    /// File system error
    case fileSystemError(String)
    
    /// LLM error during skill extraction
    case extractionError(String)
    
    /// Skill matching error
    case matchingError(String)
    
    public var errorDescription: String? {
        switch self {
        case .missingSkillFile:
            return "SKILL.md file not found in directory"
        case .invalidFormat(let details):
            return "Invalid SKILL.md format: \(details)"
        case .invalidName(let name):
            return "Invalid skill name '\(name)'. Names must be 1-64 lowercase alphanumeric characters with hyphens, no leading/trailing hyphens, no consecutive hyphens."
        case .missingDescription:
            return "Skill description is required and cannot be empty"
        case .skillAlreadyExists(let name):
            return "A skill named '\(name)' already exists"
        case .skillNotFound(let name):
            return "Skill '\(name)' not found"
        case .invalidFile(let details):
            return "Invalid file: \(details)"
        case .yamlParseError(let details):
            return "Failed to parse YAML frontmatter: \(details)"
        case .networkError(let details):
            return "Network error: \(details)"
        case .githubSkillNotFound(let name):
            return "Skill '\(name)' not found in GitHub repository"
        case .invalidGitHubURL(let url):
            return "Invalid GitHub URL: \(url). Expected format: https://github.com/owner/repo/tree/branch/path/to/skill"
        case .fileSystemError(let details):
            return "File system error: \(details)"
        case .extractionError(let details):
            return "Skill extraction failed: \(details)"
        case .matchingError(let details):
            return "Skill matching failed: \(details)"
        }
    }
}
