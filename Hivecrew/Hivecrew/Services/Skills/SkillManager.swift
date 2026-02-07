//
//  SkillManager.swift
//  Hivecrew
//
//  Service for managing skills: CRUD operations, GitHub import, local import
//

import Combine
import Foundation
import HivecrewShared

/// Service for managing Agent Skills
@MainActor
public class SkillManager: ObservableObject {
    
    // MARK: - Published Properties
    
    /// All loaded skills
    @Published public private(set) var skills: [Skill] = []
    
    /// Loading state
    @Published public private(set) var isLoading: Bool = false
    
    /// Last error (if any)
    @Published public var lastError: SkillError?
    
    // MARK: - Services
    
    /// On-device embedding service for skill matching pre-filtering
    public let embeddingService = SkillEmbeddingService()
    
    // MARK: - Constants
    
    /// Name of the skill-creator skill used for extraction
    public static let skillCreatorName = "skill-creator"
    
    /// GitHub base URL for anthropic skills (raw content)
    private static let githubBaseURL = "https://raw.githubusercontent.com/anthropics/skills/main/skills"
    
    /// Default skills from Anthropic's official repository to import on first launch
    /// These are the skills available at https://github.com/anthropics/skills/tree/main/skills/
    public static let defaultAnthropicSkills = [
        "skill-creator",
        "algorithmic-art",
        "brand-guidelines",
        "canvas-design",
        "doc-coauthoring",
        "docx",
        "frontend-design",
        "internal-comms",
        "mcp-builder",
        "pdf",
        "pptx",
        "slack-gif-creator",
        "theme-factory",
        "web-artifacts-builder",
        "webapp-testing",
        "xlsx"
    ]
    
    /// Default community skills from various GitHub repositories to import alongside Anthropic skills.
    /// Each entry is a (url, name) tuple where url is the full GitHub URL and name is the local directory name.
    public static let defaultCommunitySkills: [(url: String, name: String)] = [
        ("https://github.com/anthropics/claude-cookbooks/tree/main/skills/custom_skills/analyzing-financial-statements", "analyzing-financial-statements"),
        ("https://github.com/anthropics/claude-cookbooks/tree/main/skills/custom_skills/applying-brand-guidelines", "applying-brand-guidelines"),
        ("https://github.com/anthropics/claude-cookbooks/tree/main/skills/custom_skills/creating-financial-models", "creating-financial-models"),
        ("https://github.com/ryanbbrown/revealjs-skill/tree/main/skills/revealjs", "revealjs"),
        ("https://github.com/coffeefuelbump/csv-data-summarizer-claude-skill", "csv-data-summarizer-claude-skill"),
        ("https://github.com/K-Dense-AI/claude-scientific-skills/tree/main/scientific-skills/biopython", "biopython"),
        ("https://github.com/K-Dense-AI/claude-scientific-skills/tree/main/scientific-skills/clinical-reports", "clinical-reports"),
        ("https://github.com/K-Dense-AI/claude-scientific-skills/tree/main/scientific-skills/clinical-decision-support", "clinical-decision-support"),
        ("https://github.com/K-Dense-AI/claude-scientific-skills/tree/main/scientific-skills/infographics", "infographics"),
        ("https://github.com/K-Dense-AI/claude-scientific-skills/tree/main/scientific-skills/latex-posters", "latex-posters"),
        ("https://github.com/K-Dense-AI/claude-scientific-skills/tree/main/scientific-skills/market-research-reports", "market-research-reports"),
    ]
    
    // MARK: - Initialization
    
    public init() {
        // Load skills and bootstrap defaults on init
        Task {
            // First ensure all default skills are installed (downloads any missing defaults)
            await bootstrapDefaultSkillsIfNeeded()
            // Then load all skills
            try? await loadAllSkills()
        }
    }
    
    // MARK: - Loading
    
    /// Load all skills from disk
    @discardableResult
    public func loadAllSkills() async throws -> [Skill] {
        isLoading = true
        defer { isLoading = false }
        
        var loadedSkills: [Skill] = []
        
        let skillsDir = AppPaths.skillsDirectory
        
        guard FileManager.default.fileExists(atPath: skillsDir.path) else {
            skills = []
            return []
        }
        
        let contents = try FileManager.default.contentsOfDirectory(
            at: skillsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        
        for itemURL in contents {
            // Check if it's a directory
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: itemURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }
            
            // Check for SKILL.md
            let skillMdPath = itemURL.appendingPathComponent("SKILL.md")
            guard FileManager.default.fileExists(atPath: skillMdPath.path) else {
                continue
            }
            
            do {
                // Load local metadata first
                let skillName = itemURL.lastPathComponent
                var localMetadata = SkillParser.loadLocalMetadata(for: skillName)
                
                // Parse SKILL.md
                var skill = try SkillParser.parse(
                    at: skillMdPath,
                    isImported: localMetadata?.isImported ?? false,
                    sourceTaskId: localMetadata?.sourceTaskId
                )
                
                // Apply local metadata
                if let metadata = localMetadata {
                    skill = Skill(
                        name: skill.name,
                        description: skill.description,
                        license: skill.license,
                        compatibility: skill.compatibility,
                        metadata: skill.metadata,
                        allowedTools: skill.allowedTools,
                        instructions: skill.instructions,
                        isImported: metadata.isImported,
                        sourceTaskId: metadata.sourceTaskId,
                        createdAt: metadata.createdAt,
                        isEnabled: metadata.isEnabled
                    )
                }
                
                // Compute and cache embedding if missing or stale
                let currentMetadata = localMetadata ?? SkillParser.LocalMetadata(
                    isEnabled: skill.isEnabled,
                    isImported: skill.isImported,
                    sourceTaskId: skill.sourceTaskId,
                    createdAt: skill.createdAt
                )
                let updatedMetadata = embeddingService.ensureEmbedding(
                    for: skill,
                    existingMetadata: currentMetadata
                )
                // Save back if the embedding was computed or updated
                if updatedMetadata.embedding != nil,
                   updatedMetadata.embeddingText != localMetadata?.embeddingText {
                    try? SkillParser.saveLocalMetadata(updatedMetadata, for: skillName)
                    localMetadata = updatedMetadata
                }
                
                loadedSkills.append(skill)
            } catch {
                print("SkillManager: Failed to load skill at \(itemURL.path): \(error)")
            }
        }
        
        skills = loadedSkills.sorted { $0.name < $1.name }
        return skills
    }
    
    /// Load a single skill by name
    public func loadSkill(name: String) throws -> Skill {
        let skillPath = AppPaths.skillFilePath(name: name)
        guard FileManager.default.fileExists(atPath: skillPath.path) else {
            throw SkillError.skillNotFound(name)
        }
        
        let localMetadata = SkillParser.loadLocalMetadata(for: name)
        var skill = try SkillParser.parse(
            at: skillPath,
            isImported: localMetadata?.isImported ?? false,
            sourceTaskId: localMetadata?.sourceTaskId
        )
        
        if let metadata = localMetadata {
            skill = Skill(
                name: skill.name,
                description: skill.description,
                license: skill.license,
                compatibility: skill.compatibility,
                metadata: skill.metadata,
                allowedTools: skill.allowedTools,
                instructions: skill.instructions,
                isImported: metadata.isImported,
                sourceTaskId: metadata.sourceTaskId,
                createdAt: metadata.createdAt,
                isEnabled: metadata.isEnabled
            )
        }
        
        return skill
    }
    
    // MARK: - Refreshing
    
    /// Refresh the skills list by reloading all skills from disk
    /// Call this when new skills have been added externally
    public func refreshSkills() async {
        do {
            try await loadAllSkills()
        } catch {
            print("SkillManager: Failed to refresh skills: \(error.localizedDescription)")
            lastError = .fileSystemError("Failed to refresh skills: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Saving
    
    /// Save a skill to disk
    public func saveSkill(_ skill: Skill) throws {
        // Validate name
        guard Skill.isValidName(skill.name) else {
            throw SkillError.invalidName(skill.name)
        }
        
        // Create skill directory
        let skillDir = AppPaths.skillDirectory(name: skill.name)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        
        // Write SKILL.md
        let content = SkillParser.serialize(skill)
        let skillPath = AppPaths.skillFilePath(name: skill.name)
        try content.write(to: skillPath, atomically: true, encoding: .utf8)
        
        // Preserve existing embedding data from previous metadata
        let existingMetadata = SkillParser.loadLocalMetadata(for: skill.name)
        
        // Compute embedding for the (possibly updated) description
        var localMetadata = SkillParser.LocalMetadata(
            isEnabled: skill.isEnabled,
            isImported: skill.isImported,
            sourceTaskId: skill.sourceTaskId,
            createdAt: skill.createdAt,
            embedding: existingMetadata?.embedding,
            embeddingText: existingMetadata?.embeddingText
        )
        // Recompute if description changed
        localMetadata = embeddingService.ensureEmbedding(for: skill, existingMetadata: localMetadata)
        try SkillParser.saveLocalMetadata(localMetadata, for: skill.name)
        
        // Refresh skills list
        Task {
            try? await loadAllSkills()
        }
    }
    
    // MARK: - Deleting
    
    /// Delete a skill and its directory
    public func deleteSkill(name: String) throws {
        let skillDir = AppPaths.skillDirectory(name: name)
        guard FileManager.default.fileExists(atPath: skillDir.path) else {
            throw SkillError.skillNotFound(name)
        }
        
        try FileManager.default.removeItem(at: skillDir)
        
        // Refresh skills list
        skills.removeAll { $0.name == name }
    }
    
    // MARK: - Enable/Disable
    
    /// Toggle skill enabled state
    public func setEnabled(_ enabled: Bool, for skillName: String) {
        guard let index = skills.firstIndex(where: { $0.name == skillName }) else {
            return
        }
        
        var skill = skills[index]
        skill = Skill(
            name: skill.name,
            description: skill.description,
            license: skill.license,
            compatibility: skill.compatibility,
            metadata: skill.metadata,
            allowedTools: skill.allowedTools,
            instructions: skill.instructions,
            isImported: skill.isImported,
            sourceTaskId: skill.sourceTaskId,
            createdAt: skill.createdAt,
            isEnabled: enabled
        )
        
        skills[index] = skill
        
        // Save local metadata (preserving cached embedding)
        do {
            let existingMetadata = SkillParser.loadLocalMetadata(for: skillName)
            let localMetadata = SkillParser.LocalMetadata(
                isEnabled: enabled,
                isImported: skill.isImported,
                sourceTaskId: skill.sourceTaskId,
                createdAt: skill.createdAt,
                embedding: existingMetadata?.embedding,
                embeddingText: existingMetadata?.embeddingText
            )
            try SkillParser.saveLocalMetadata(localMetadata, for: skillName)
        } catch {
            print("SkillManager: Failed to save enabled state: \(error)")
        }
    }
    
    /// Get only enabled skills (for matching)
    public var enabledSkills: [Skill] {
        skills.filter { $0.isEnabled }
    }
    
    // MARK: - Local Import
    
    /// Import a skill from a local directory containing SKILL.md
    public func importFromLocalDirectory(_ directoryURL: URL) throws -> Skill {
        let skillMdPath = directoryURL.appendingPathComponent("SKILL.md")
        
        guard FileManager.default.fileExists(atPath: skillMdPath.path) else {
            throw SkillError.missingSkillFile
        }
        
        // Parse to get skill name
        let skill = try SkillParser.parse(at: skillMdPath, isImported: true)
        
        // Check if skill already exists
        let destDir = AppPaths.skillDirectory(name: skill.name)
        if FileManager.default.fileExists(atPath: destDir.path) {
            throw SkillError.skillAlreadyExists(skill.name)
        }
        
        // Copy entire directory to Skills folder
        try FileManager.default.copyItem(at: directoryURL, to: destDir)
        
        // Save local metadata
        let localMetadata = SkillParser.LocalMetadata(
            isEnabled: true,
            isImported: true,
            sourceTaskId: nil,
            createdAt: Date()
        )
        try SkillParser.saveLocalMetadata(localMetadata, for: skill.name)
        
        // Refresh skills list
        Task {
            try? await loadAllSkills()
        }
        
        return skill
    }
    
    /// Import a single SKILL.md file (creates minimal skill directory)
    public func importFromSkillFile(_ fileURL: URL) throws -> Skill {
        guard fileURL.lastPathComponent == "SKILL.md" else {
            throw SkillError.invalidFile("Expected SKILL.md file")
        }
        
        // Parse to get skill name
        let skill = try SkillParser.parse(at: fileURL, isImported: true)
        
        // Check if skill already exists
        let destDir = AppPaths.skillDirectory(name: skill.name)
        if FileManager.default.fileExists(atPath: destDir.path) {
            throw SkillError.skillAlreadyExists(skill.name)
        }
        
        // Create skill directory and copy file
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fileURL, to: AppPaths.skillFilePath(name: skill.name))
        
        // Save local metadata
        let localMetadata = SkillParser.LocalMetadata(
            isEnabled: true,
            isImported: true,
            sourceTaskId: nil,
            createdAt: Date()
        )
        try SkillParser.saveLocalMetadata(localMetadata, for: skill.name)
        
        // Refresh skills list
        Task {
            try? await loadAllSkills()
        }
        
        return skill
    }
    
    // MARK: - GitHub Import
    
    /// Import a skill from a GitHub URL
    /// Accepts URLs like:
    /// - https://github.com/anthropics/skills/tree/main/skills/skill-creator
    /// - https://github.com/anthropics/skills/blob/main/skills/skill-creator/SKILL.md
    /// - https://github.com/user/repo/tree/branch/path/to/skill
    /// - https://github.com/user/repo  (repo root, SKILL.md at root level)
    /// - Parameter nameOverride: Optional name to use as the local skill directory name.
    public func importFromGitHubURL(_ urlString: String, nameOverride: String? = nil) async throws -> Skill {
        // Parse the GitHub URL to extract components
        guard let parsed = parseGitHubURL(urlString) else {
            throw SkillError.invalidGitHubURL(urlString)
        }
        
        // Download from the raw URL
        return try await importFromGitHubComponents(
            owner: parsed.owner,
            repo: parsed.repo,
            branch: parsed.branch,
            skillPath: parsed.skillPath,
            nameOverride: nameOverride
        )
    }
    
    /// Parse a GitHub URL into its components
    private func parseGitHubURL(_ urlString: String) -> (owner: String, repo: String, branch: String, skillPath: String)? {
        // Normalize URL
        var normalized = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove trailing slash
        if normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        
        // Remove SKILL.md if present
        if normalized.hasSuffix("/SKILL.md") {
            normalized = String(normalized.dropLast("/SKILL.md".count))
        }
        
        // Parse GitHub URL patterns:
        // https://github.com/owner/repo/tree/branch/path/to/skill
        // https://github.com/owner/repo/blob/branch/path/to/skill
        // https://github.com/owner/repo  (repo root, assumes branch=main)
        
        guard let url = URL(string: normalized) else { return nil }
        guard url.host == "github.com" || url.host == "www.github.com" else { return nil }
        
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        guard pathComponents.count >= 2 else { return nil }
        
        let owner = pathComponents[0]
        let repo = pathComponents[1]
        
        // Handle repo-root URLs (just owner/repo, no tree/blob/branch)
        if pathComponents.count == 2 {
            return (owner: owner, repo: repo, branch: "main", skillPath: "")
        }
        
        guard pathComponents.count >= 4 else { return nil }
        
        let treeOrBlob = pathComponents[2] // "tree" or "blob"
        let branch = pathComponents[3]
        
        guard treeOrBlob == "tree" || treeOrBlob == "blob" else { return nil }
        
        // The rest is the path to the skill directory
        let skillPathComponents = Array(pathComponents.dropFirst(4))
        let skillPath = skillPathComponents.joined(separator: "/")
        
        return (owner: owner, repo: repo, branch: branch, skillPath: skillPath)
    }
    
    /// Import from parsed GitHub components
    /// - Parameter nameOverride: Optional name to use instead of deriving from the path. Useful for repo-root skills.
    private func importFromGitHubComponents(owner: String, repo: String, branch: String, skillPath: String, nameOverride: String? = nil) async throws -> Skill {
        // Extract skill name: use override, last path component, or repo name for root-level skills
        let skillName: String
        if let override = nameOverride, !override.isEmpty {
            skillName = override
        } else if let lastComponent = skillPath.split(separator: "/").last.map(String.init), !lastComponent.isEmpty {
            skillName = lastComponent
        } else {
            // Repo-root skill: use repository name
            skillName = repo
        }
        
        // Validate skill name
        guard Skill.isValidName(skillName) else {
            throw SkillError.invalidName(skillName)
        }
        
        // Check if skill already exists
        let destDir = AppPaths.skillDirectory(name: skillName)
        if FileManager.default.fileExists(atPath: destDir.path) {
            throw SkillError.skillAlreadyExists(skillName)
        }
        
        // Build raw content URL — handle empty skillPath for repo-root skills
        let rawBaseURL: String
        if skillPath.isEmpty {
            rawBaseURL = "https://raw.githubusercontent.com/\(owner)/\(repo)/\(branch)"
        } else {
            rawBaseURL = "https://raw.githubusercontent.com/\(owner)/\(repo)/\(branch)/\(skillPath)"
        }
        let skillMdURL = URL(string: "\(rawBaseURL)/SKILL.md")!
        
        // Download SKILL.md
        let (data, response) = try await URLSession.shared.data(from: skillMdURL)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SkillError.networkError("Invalid response")
        }
        
        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 404 {
                throw SkillError.githubSkillNotFound(skillName)
            }
            throw SkillError.networkError("HTTP \(httpResponse.statusCode)")
        }
        
        // Create skill directory
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        
        // Save SKILL.md
        try data.write(to: AppPaths.skillFilePath(name: skillName))
        
        // Download all other files and directories from the skill folder
        await downloadAllSkillContents(
            owner: owner,
            repo: repo,
            branch: branch,
            skillPath: skillPath,
            skillName: skillName
        )
        
        // Parse and save local metadata
        let skill = try SkillParser.parse(
            at: AppPaths.skillFilePath(name: skillName),
            isImported: true
        )
        
        let localMetadata = SkillParser.LocalMetadata(
            isEnabled: true,
            isImported: true,
            sourceTaskId: nil,
            createdAt: Date()
        )
        try SkillParser.saveLocalMetadata(localMetadata, for: skillName)
        
        // Refresh skills list
        try await loadAllSkills()
        
        return skill
    }
    
    /// Import a skill from the anthropics/skills GitHub repository by name
    public func importFromGitHub(skillName: String) async throws -> Skill {
        // Validate skill name
        guard Skill.isValidName(skillName) else {
            throw SkillError.invalidName(skillName)
        }
        
        // Check if skill already exists
        let destDir = AppPaths.skillDirectory(name: skillName)
        if FileManager.default.fileExists(atPath: destDir.path) {
            throw SkillError.skillAlreadyExists(skillName)
        }
        
        // Download SKILL.md first to verify the skill exists
        let skillMdURL = URL(string: "\(Self.githubBaseURL)/\(skillName)/SKILL.md")!
        
        let (data, response) = try await URLSession.shared.data(from: skillMdURL)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SkillError.networkError("Invalid response")
        }
        
        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 404 {
                throw SkillError.githubSkillNotFound(skillName)
            }
            throw SkillError.networkError("HTTP \(httpResponse.statusCode)")
        }
        
        // Create skill directory
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        
        // Save SKILL.md
        try data.write(to: AppPaths.skillFilePath(name: skillName))
        
        // Download all other files and directories from the skill folder
        await downloadAllSkillContents(
            owner: "anthropics",
            repo: "skills",
            branch: "main",
            skillPath: "skills/\(skillName)",
            skillName: skillName
        )
        
        // Parse and save local metadata
        let skill = try SkillParser.parse(
            at: AppPaths.skillFilePath(name: skillName),
            isImported: true
        )
        
        let localMetadata = SkillParser.LocalMetadata(
            isEnabled: true,
            isImported: true,
            sourceTaskId: nil,
            createdAt: Date()
        )
        try SkillParser.saveLocalMetadata(localMetadata, for: skillName)
        
        // Refresh skills list
        try await loadAllSkills()
        
        return skill
    }
    
    /// Download all contents of a skill directory from GitHub (files and subdirectories)
    private func downloadAllSkillContents(
        owner: String,
        repo: String,
        branch: String,
        skillPath: String,
        skillName: String
    ) async {
        // Use GitHub API to list all contents
        let apiURL = "https://api.github.com/repos/\(owner)/\(repo)/contents/\(skillPath)?ref=\(branch)"
        
        guard let url = URL(string: apiURL) else { return }
        
        do {
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                print("SkillManager: Failed to list skill contents via API")
                return
            }
            
            guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return
            }
            
            let destDir = AppPaths.skillDirectory(name: skillName)
            
            for item in items {
                guard let name = item["name"] as? String,
                      let type = item["type"] as? String else {
                    continue
                }
                
                // Skip SKILL.md (already downloaded) and metadata files
                if name == "SKILL.md" || name == ".skill-metadata.json" {
                    continue
                }
                
                if type == "file" {
                    // Download file
                    if let downloadURL = item["download_url"] as? String,
                       let fileURL = URL(string: downloadURL) {
                        await downloadFile(from: fileURL, to: destDir.appendingPathComponent(name))
                    }
                } else if type == "dir" {
                    // Recursively download directory
                    await downloadDirectoryRecursively(
                        owner: owner,
                        repo: repo,
                        branch: branch,
                        path: "\(skillPath)/\(name)",
                        localDir: destDir.appendingPathComponent(name)
                    )
                }
            }
        } catch {
            print("SkillManager: Error downloading skill contents: \(error.localizedDescription)")
        }
    }
    
    /// Recursively download a directory from GitHub
    private func downloadDirectoryRecursively(
        owner: String,
        repo: String,
        branch: String,
        path: String,
        localDir: URL
    ) async {
        let apiURL = "https://api.github.com/repos/\(owner)/\(repo)/contents/\(path)?ref=\(branch)"
        
        guard let url = URL(string: apiURL) else { return }
        
        do {
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return
            }
            
            guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return
            }
            
            // Create local directory
            try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
            
            for item in items {
                guard let name = item["name"] as? String,
                      let type = item["type"] as? String else {
                    continue
                }
                
                if type == "file" {
                    if let downloadURL = item["download_url"] as? String,
                       let fileURL = URL(string: downloadURL) {
                        await downloadFile(from: fileURL, to: localDir.appendingPathComponent(name))
                    }
                } else if type == "dir" {
                    await downloadDirectoryRecursively(
                        owner: owner,
                        repo: repo,
                        branch: branch,
                        path: "\(path)/\(name)",
                        localDir: localDir.appendingPathComponent(name)
                    )
                }
            }
        } catch {
            print("SkillManager: Error downloading directory \(path): \(error.localizedDescription)")
        }
    }
    
    /// Download a single file from URL to local path
    private func downloadFile(from url: URL, to localPath: URL) async {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return
            }
            
            try data.write(to: localPath)
            print("SkillManager: Downloaded \(localPath.lastPathComponent)")
        } catch {
            print("SkillManager: Failed to download \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
    
    // MARK: - Bootstrap Default Skills
    
    /// Key for tracking whether initial bootstrap has completed (kept for migration purposes)
    private static let defaultSkillsBootstrappedKey = "defaultSkillsBootstrapped"
    
    /// Ensure all default skills (Anthropic + community) are installed.
    /// Runs on every launch and downloads any missing default skills, so new skills
    /// added to the defaults list are automatically picked up on the next app start.
    public func bootstrapDefaultSkillsIfNeeded() async {
        // Collect all default skill names that should be installed
        let anthropicNames = Set(Self.defaultAnthropicSkills)
        let communityNames = Set(Self.defaultCommunitySkills.map { $0.name })
        let allDefaultNames = anthropicNames.union(communityNames)
        
        // Determine which skills are missing
        let missingNames = allDefaultNames.filter { name in
            let skillPath = AppPaths.skillFilePath(name: name)
            return !FileManager.default.fileExists(atPath: skillPath.path)
        }
        
        guard !missingNames.isEmpty else {
            print("SkillManager: All default skills already installed")
            return
        }
        
        print("SkillManager: Installing \(missingNames.count) missing default skill(s)...")
        
        var successCount = 0
        var failedSkills: [String] = []
        
        // Install missing Anthropic skills (from anthropics/skills repo)
        for skillName in Self.defaultAnthropicSkills where missingNames.contains(skillName) {
            do {
                _ = try await importFromGitHub(skillName: skillName)
                print("SkillManager: Successfully imported Anthropic skill '\(skillName)'")
                successCount += 1
            } catch {
                print("SkillManager: Failed to import Anthropic skill '\(skillName)': \(error.localizedDescription)")
                failedSkills.append(skillName)
            }
        }
        
        // Install missing community skills (from various GitHub repos)
        for entry in Self.defaultCommunitySkills where missingNames.contains(entry.name) {
            do {
                _ = try await importFromGitHubURL(entry.url, nameOverride: entry.name)
                print("SkillManager: Successfully imported community skill '\(entry.name)'")
                successCount += 1
            } catch {
                print("SkillManager: Failed to import community skill '\(entry.name)': \(error.localizedDescription)")
                failedSkills.append(entry.name)
            }
        }
        
        // Mark as bootstrapped (for migration tracking)
        UserDefaults.standard.set(true, forKey: Self.defaultSkillsBootstrappedKey)
        
        let totalDefaults = allDefaultNames.count
        print("SkillManager: Bootstrap complete. Installed \(successCount)/\(missingNames.count) missing skills (\(totalDefaults) total defaults)")
        if !failedSkills.isEmpty {
            print("SkillManager: Failed skills: \(failedSkills.joined(separator: ", "))")
        }
        
        // Refresh skills list
        let _ = try? await loadAllSkills()
    }
    
    /// Ensure the skill-creator skill is available (for skill extraction)
    public func ensureSkillCreatorAvailable() async throws {
        let skillPath = AppPaths.skillFilePath(name: Self.skillCreatorName)
        
        // Check if already installed
        if FileManager.default.fileExists(atPath: skillPath.path) {
            return
        }
        
        // Import from GitHub
        _ = try await importFromGitHub(skillName: Self.skillCreatorName)
    }
    
    /// Check if skill-creator is available
    public var isSkillCreatorAvailable: Bool {
        FileManager.default.fileExists(atPath: AppPaths.skillFilePath(name: Self.skillCreatorName).path)
    }
    
    // MARK: - Skill Summaries
    
    /// Get skill summaries for matching (name + description only)
    public var skillSummaries: [SkillSummary] {
        enabledSkills.map { SkillSummary(from: $0) }
    }
    
    // MARK: - Skill Files for VM
    
    /// Copy all skill files (except SKILL.md) to a destination directory
    /// Creates a subdirectory for each skill: destination/skill-name/
    /// Returns the list of skill names that had files copied
    @discardableResult
    public func copySkillFiles(for skills: [Skill], to destinationDir: URL) throws -> [String] {
        let fm = FileManager.default
        var copiedSkills: [String] = []
        
        for skill in skills {
            let skillDir = AppPaths.skillDirectory(name: skill.name)
            
            // Check if skill directory exists
            guard fm.fileExists(atPath: skillDir.path) else {
                continue
            }
            
            // Get contents of skill directory
            guard let contents = try? fm.contentsOfDirectory(at: skillDir, includingPropertiesForKeys: [.isDirectoryKey]),
                  !contents.isEmpty else {
                continue
            }
            
            // Filter out SKILL.md and metadata (these are handled separately)
            let filesToCopy = contents.filter { url in
                let name = url.lastPathComponent
                return name != "SKILL.md" && name != ".skill-metadata.json"
            }
            
            guard !filesToCopy.isEmpty else {
                continue
            }
            
            // Create skill directory at destination: destination/skill-name/
            let skillDestDir = destinationDir.appendingPathComponent(skill.name, isDirectory: true)
            try fm.createDirectory(at: skillDestDir, withIntermediateDirectories: true)
            
            // Copy all files and directories
            for itemURL in filesToCopy {
                let destURL = skillDestDir.appendingPathComponent(itemURL.lastPathComponent)
                try? fm.removeItem(at: destURL) // Remove if exists
                try fm.copyItem(at: itemURL, to: destURL)
            }
            
            copiedSkills.append(skill.name)
            print("SkillManager: Copied files for skill '\(skill.name)' to \(skillDestDir.path)")
        }
        
        return copiedSkills
    }
}
