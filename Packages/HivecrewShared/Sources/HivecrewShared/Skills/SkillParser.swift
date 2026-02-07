//
//  SkillParser.swift
//  HivecrewShared
//
//  Parses and serializes SKILL.md files following the Agent Skills spec
//

import Foundation

/// Parses SKILL.md format: YAML frontmatter + markdown body
public struct SkillParser {
    
    // MARK: - Parsing
    
    /// Parse a SKILL.md file into a Skill object
    /// - Parameters:
    ///   - url: Path to the SKILL.md file
    ///   - isImported: Whether this skill was imported from an external source
    ///   - sourceTaskId: Optional task ID if extracted from a task
    /// - Returns: Parsed Skill object
    public static func parse(
        at url: URL,
        isImported: Bool = false,
        sourceTaskId: String? = nil
    ) throws -> Skill {
        let content = try String(contentsOf: url, encoding: .utf8)
        return try parse(content: content, isImported: isImported, sourceTaskId: sourceTaskId)
    }
    
    /// Parse SKILL.md content string into a Skill object
    public static func parse(
        content: String,
        isImported: Bool = false,
        sourceTaskId: String? = nil
    ) throws -> Skill {
        // Split frontmatter from body
        // Format: ---\n{yaml}\n---\n{markdown}
        guard content.hasPrefix("---") else {
            throw SkillError.invalidFormat("Missing YAML frontmatter (must start with ---)")
        }
        
        // Find the closing ---
        let contentAfterFirstDelimiter = String(content.dropFirst(3))
        guard let endOfFrontmatter = contentAfterFirstDelimiter.range(of: "\n---") else {
            throw SkillError.invalidFormat("Invalid frontmatter delimiter (missing closing ---)")
        }
        
        let yamlString = String(contentAfterFirstDelimiter[..<endOfFrontmatter.lowerBound])
        let markdownBody = String(contentAfterFirstDelimiter[endOfFrontmatter.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Parse YAML frontmatter
        let frontmatter = try parseFrontmatter(yamlString)
        
        // Validate required fields
        guard let name = frontmatter["name"] else {
            throw SkillError.invalidFormat("Missing required 'name' field")
        }
        guard Skill.isValidName(name) else {
            throw SkillError.invalidName(name)
        }
        guard let description = frontmatter["description"], !description.isEmpty else {
            throw SkillError.missingDescription
        }
        
        // Parse optional metadata
        let metadata = parseMetadata(from: frontmatter)
        
        return Skill(
            name: name,
            description: description,
            license: frontmatter["license"],
            compatibility: frontmatter["compatibility"],
            metadata: metadata,
            allowedTools: frontmatter["allowed-tools"],
            instructions: markdownBody,
            isImported: isImported,
            sourceTaskId: sourceTaskId,
            createdAt: Date(),
            isEnabled: true
        )
    }
    
    /// Parse simple YAML frontmatter (key: value pairs)
    private static func parseFrontmatter(_ yaml: String) throws -> [String: String] {
        var result: [String: String] = [:]
        var currentKey: String?
        var isInMetadata = false
        var metadataLines: [String] = []
        
        let lines = yaml.components(separatedBy: .newlines)
        
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            
            // Skip empty lines
            if trimmedLine.isEmpty { continue }
            
            // Check if we're in metadata block
            if isInMetadata {
                if line.hasPrefix("  ") || line.hasPrefix("\t") {
                    // Continuation of metadata
                    metadataLines.append(trimmedLine)
                    continue
                } else {
                    // End of metadata block
                    isInMetadata = false
                    result["_metadata_raw"] = metadataLines.joined(separator: "\n")
                }
            }
            
            // Parse key: value
            if let colonIndex = trimmedLine.firstIndex(of: ":") {
                let key = String(trimmedLine[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmedLine[trimmedLine.index(after: colonIndex)...])
                    .trimmingCharacters(in: .whitespaces)
                
                if key == "metadata" && value.isEmpty {
                    // Start of metadata block
                    isInMetadata = true
                    metadataLines = []
                    currentKey = key
                } else {
                    result[key] = value
                }
            }
        }
        
        // Handle metadata block at end
        if isInMetadata && !metadataLines.isEmpty {
            result["_metadata_raw"] = metadataLines.joined(separator: "\n")
        }
        
        return result
    }
    
    /// Parse metadata from frontmatter
    private static func parseMetadata(from frontmatter: [String: String]) -> [String: String]? {
        guard let rawMetadata = frontmatter["_metadata_raw"] else {
            return nil
        }
        
        var metadata: [String: String] = [:]
        let lines = rawMetadata.components(separatedBy: .newlines)
        
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if let colonIndex = trimmedLine.firstIndex(of: ":") {
                let key = String(trimmedLine[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                var value = String(trimmedLine[trimmedLine.index(after: colonIndex)...])
                    .trimmingCharacters(in: .whitespaces)
                // Remove quotes if present
                if value.hasPrefix("\"") && value.hasSuffix("\"") {
                    value = String(value.dropFirst().dropLast())
                }
                metadata[key] = value
            }
        }
        
        return metadata.isEmpty ? nil : metadata
    }
    
    // MARK: - Serialization
    
    /// Generate SKILL.md content from a Skill
    public static func serialize(_ skill: Skill) -> String {
        var content = "---\n"
        content += "name: \(skill.name)\n"
        content += "description: \(escapeYamlString(skill.description))\n"
        
        if let license = skill.license {
            content += "license: \(license)\n"
        }
        
        if let compatibility = skill.compatibility {
            content += "compatibility: \(escapeYamlString(compatibility))\n"
        }
        
        if let metadata = skill.metadata, !metadata.isEmpty {
            content += "metadata:\n"
            for (key, value) in metadata.sorted(by: { $0.key < $1.key }) {
                content += "  \(key): \"\(value)\"\n"
            }
        }
        
        if let allowedTools = skill.allowedTools {
            content += "allowed-tools: \(allowedTools)\n"
        }
        
        content += "---\n\n"
        content += skill.instructions
        
        return content
    }
    
    /// Escape a string for YAML (wrap in quotes if contains special chars)
    private static func escapeYamlString(_ string: String) -> String {
        let needsQuoting = string.contains(":") ||
                          string.contains("#") ||
                          string.contains("'") ||
                          string.contains("\"") ||
                          string.contains("\n") ||
                          string.hasPrefix(" ") ||
                          string.hasSuffix(" ")
        
        if needsQuoting {
            // Escape internal quotes and wrap in quotes
            let escaped = string.replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        
        return string
    }
}

// MARK: - Local Metadata Storage

extension SkillParser {
    /// Path to local metadata file for a skill (stores isEnabled, sourceTaskId, etc.)
    public static func localMetadataPath(for skillName: String) -> URL {
        AppPaths.skillDirectory(name: skillName).appendingPathComponent(".hivecrew-metadata.json")
    }
    
    /// Local metadata that's stored separately from SKILL.md
    public struct LocalMetadata: Codable {
        public var isEnabled: Bool
        public var isImported: Bool
        public var sourceTaskId: String?
        public var createdAt: Date
        /// Cached sentence embedding vector (512-dim from NLEmbedding)
        public var embedding: [Double]?
        /// The description text that was embedded, used to detect when recomputation is needed
        public var embeddingText: String?
        
        public init(
            isEnabled: Bool = true,
            isImported: Bool = false,
            sourceTaskId: String? = nil,
            createdAt: Date = Date(),
            embedding: [Double]? = nil,
            embeddingText: String? = nil
        ) {
            self.isEnabled = isEnabled
            self.isImported = isImported
            self.sourceTaskId = sourceTaskId
            self.createdAt = createdAt
            self.embedding = embedding
            self.embeddingText = embeddingText
        }
    }
    
    /// Save local metadata for a skill
    public static func saveLocalMetadata(_ metadata: LocalMetadata, for skillName: String) throws {
        let path = localMetadataPath(for: skillName)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        try data.write(to: path)
    }
    
    /// Load local metadata for a skill
    public static func loadLocalMetadata(for skillName: String) -> LocalMetadata? {
        let path = localMetadataPath(for: skillName)
        guard FileManager.default.fileExists(atPath: path.path) else {
            return nil
        }
        
        do {
            let data = try Data(contentsOf: path)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(LocalMetadata.self, from: data)
        } catch {
            return nil
        }
    }
}
