//
//  Skill.swift
//  HivecrewShared
//
//  Data model for Agent Skills following the Agent Skills specification
//  https://agentskills.io/specification
//

import Foundation

/// Represents a skill following the Agent Skills spec
/// Storage: ~/Library/Application Support/Hivecrew/Skills/{name}/SKILL.md
public struct Skill: Codable, Identifiable, Sendable, Hashable {
    // MARK: - Required Fields (from YAML frontmatter)
    
    /// Skill name (1-64 chars, lowercase alphanumeric + hyphens)
    /// Must match parent directory name
    /// Constraints: no leading/trailing hyphens, no consecutive hyphens
    public let name: String
    
    /// What the skill does and when to use it (1-1024 chars)
    /// Should include keywords that help agents identify relevant tasks
    public let description: String
    
    // MARK: - Optional Fields (from YAML frontmatter)
    
    /// License name or reference to bundled LICENSE file
    public let license: String?
    
    /// Environment requirements (1-500 chars)
    /// e.g., "Requires git, docker, jq, and access to the internet"
    public let compatibility: String?
    
    /// Arbitrary key-value metadata
    /// e.g., ["author": "example-org", "version": "1.0"]
    public let metadata: [String: String]?
    
    /// Space-delimited list of pre-approved tools (experimental)
    /// e.g., "Bash(git:*) Bash(jq:*) Read"
    public let allowedTools: String?
    
    // MARK: - Body Content
    
    /// Full markdown body after frontmatter (skill instructions)
    /// Recommended: step-by-step instructions, examples, edge cases
    /// Should be < 5000 tokens, < 500 lines
    public let instructions: String
    
    // MARK: - Local Metadata (not part of SKILL.md)
    
    /// Whether this skill was imported from GitHub vs extracted locally
    public let isImported: Bool
    
    /// Task ID if extracted from a completed task
    public let sourceTaskId: String?
    
    /// When the skill was added locally
    public let createdAt: Date
    
    /// Whether the skill is enabled for matching
    public var isEnabled: Bool
    
    // MARK: - Computed
    
    public var id: String { name }
    
    // MARK: - Initialization
    
    public init(
        name: String,
        description: String,
        license: String? = nil,
        compatibility: String? = nil,
        metadata: [String: String]? = nil,
        allowedTools: String? = nil,
        instructions: String,
        isImported: Bool = false,
        sourceTaskId: String? = nil,
        createdAt: Date = Date(),
        isEnabled: Bool = true
    ) {
        self.name = name
        self.description = description
        self.license = license
        self.compatibility = compatibility
        self.metadata = metadata
        self.allowedTools = allowedTools
        self.instructions = instructions
        self.isImported = isImported
        self.sourceTaskId = sourceTaskId
        self.createdAt = createdAt
        self.isEnabled = isEnabled
    }
    
    // MARK: - Hashable
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }
    
    public static func == (lhs: Skill, rhs: Skill) -> Bool {
        lhs.name == rhs.name
    }
}

// MARK: - Name Validation

extension Skill {
    /// Validates skill name per Agent Skills spec
    /// - Must be 1-64 characters
    /// - May only contain lowercase alphanumeric characters and hyphens
    /// - Must not start or end with hyphen
    /// - Must not contain consecutive hyphens
    public static func isValidName(_ name: String) -> Bool {
        guard (1...64).contains(name.count) else { return false }
        guard !name.hasPrefix("-"), !name.hasSuffix("-") else { return false }
        guard !name.contains("--") else { return false }
        
        let allowed = CharacterSet.lowercaseLetters
            .union(.decimalDigits)
            .union(CharacterSet(charactersIn: "-"))
        
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
    
    /// Generates a valid skill name from a task description
    /// Converts to lowercase, replaces spaces/special chars with hyphens, truncates to 64 chars
    public static func generateName(from taskDescription: String) -> String {
        // Extract key words from task description
        let words = taskDescription
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && $0.count > 2 }
            .prefix(5)
        
        var name = words.joined(separator: "-")
        
        // Ensure valid format
        name = name.replacingOccurrences(of: "--", with: "-")
        if name.hasPrefix("-") { name.removeFirst() }
        if name.hasSuffix("-") { name.removeLast() }
        
        // Truncate to 64 chars
        if name.count > 64 {
            name = String(name.prefix(64))
            if name.hasSuffix("-") { name.removeLast() }
        }
        
        // Fallback if empty
        if name.isEmpty {
            name = "custom-skill-\(Int(Date().timeIntervalSince1970))"
        }
        
        return name
    }
}

// MARK: - Skill Summary (for matching)

/// Lightweight skill summary used for matching (name + description only)
/// Following progressive disclosure pattern
public struct SkillSummary: Codable, Sendable {
    public let name: String
    public let description: String
    
    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }
    
    public init(from skill: Skill) {
        self.name = skill.name
        self.description = skill.description
    }
}
