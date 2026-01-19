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
    
    // MARK: - Initialization
    
    public init() {
        // Load skills and bootstrap defaults on init
        Task {
            // First bootstrap default skills if this is a fresh install
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
                let localMetadata = SkillParser.loadLocalMetadata(for: skillName)
                
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
        
        // Save local metadata
        let localMetadata = SkillParser.LocalMetadata(
            isEnabled: skill.isEnabled,
            isImported: skill.isImported,
            sourceTaskId: skill.sourceTaskId,
            createdAt: skill.createdAt
        )
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
        
        // Save local metadata
        do {
            let localMetadata = SkillParser.LocalMetadata(
                isEnabled: enabled,
                isImported: skill.isImported,
                sourceTaskId: skill.sourceTaskId,
                createdAt: skill.createdAt
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
    public func importFromGitHubURL(_ urlString: String) async throws -> Skill {
        // Parse the GitHub URL to extract components
        guard let parsed = parseGitHubURL(urlString) else {
            throw SkillError.invalidGitHubURL(urlString)
        }
        
        // Download from the raw URL
        return try await importFromGitHubComponents(
            owner: parsed.owner,
            repo: parsed.repo,
            branch: parsed.branch,
            skillPath: parsed.skillPath
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
        
        guard let url = URL(string: normalized) else { return nil }
        guard url.host == "github.com" || url.host == "www.github.com" else { return nil }
        
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        guard pathComponents.count >= 4 else { return nil }
        
        let owner = pathComponents[0]
        let repo = pathComponents[1]
        let treeOrBlob = pathComponents[2] // "tree" or "blob"
        let branch = pathComponents[3]
        
        guard treeOrBlob == "tree" || treeOrBlob == "blob" else { return nil }
        
        // The rest is the path to the skill directory
        let skillPathComponents = Array(pathComponents.dropFirst(4))
        let skillPath = skillPathComponents.joined(separator: "/")
        
        return (owner: owner, repo: repo, branch: branch, skillPath: skillPath)
    }
    
    /// Import from parsed GitHub components
    private func importFromGitHubComponents(owner: String, repo: String, branch: String, skillPath: String) async throws -> Skill {
        // Extract skill name from path (last component)
        let skillName = skillPath.split(separator: "/").last.map(String.init) ?? skillPath
        
        // Validate skill name
        guard Skill.isValidName(skillName) else {
            throw SkillError.invalidName(skillName)
        }
        
        // Check if skill already exists
        let destDir = AppPaths.skillDirectory(name: skillName)
        if FileManager.default.fileExists(atPath: destDir.path) {
            throw SkillError.skillAlreadyExists(skillName)
        }
        
        // Build raw content URL
        let rawBaseURL = "https://raw.githubusercontent.com/\(owner)/\(repo)/\(branch)/\(skillPath)"
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
        
        // Try to download optional directories (scripts/, references/, assets/)
        await downloadOptionalDirectoryFromURL(rawBaseURL: rawBaseURL, skillName: skillName, dirName: "scripts")
        await downloadOptionalDirectoryFromURL(rawBaseURL: rawBaseURL, skillName: skillName, dirName: "references")
        await downloadOptionalDirectoryFromURL(rawBaseURL: rawBaseURL, skillName: skillName, dirName: "assets")
        
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
        
        // Download SKILL.md
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
        
        // Try to download optional directories (scripts/, references/, assets/)
        await downloadOptionalDirectory(skillName: skillName, dirName: "scripts")
        await downloadOptionalDirectory(skillName: skillName, dirName: "references")
        await downloadOptionalDirectory(skillName: skillName, dirName: "assets")
        
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
    
    /// Download optional directory from GitHub (best effort) - for anthropics/skills repo
    private func downloadOptionalDirectory(skillName: String, dirName: String) async {
        await downloadOptionalDirectoryFromURL(
            rawBaseURL: "\(Self.githubBaseURL)/\(skillName)",
            skillName: skillName,
            dirName: dirName
        )
    }
    
    /// Download optional directory from a custom GitHub URL using GitHub API
    private func downloadOptionalDirectoryFromURL(rawBaseURL: String, skillName: String, dirName: String) async {
        // Parse the raw URL to get API URL components
        // rawBaseURL format: https://raw.githubusercontent.com/owner/repo/branch/path
        guard let rawURL = URL(string: rawBaseURL),
              rawURL.pathComponents.count >= 4 else {
            return
        }
        
        let pathComponents = rawURL.pathComponents.filter { $0 != "/" }
        guard pathComponents.count >= 3 else { return }
        
        let owner = pathComponents[0]
        let repo = pathComponents[1]
        let branch = pathComponents[2]
        let skillPath = pathComponents.dropFirst(3).joined(separator: "/")
        
        // Use GitHub API to list directory contents
        let apiURL = "https://api.github.com/repos/\(owner)/\(repo)/contents/\(skillPath)/\(dirName)?ref=\(branch)"
        
        guard let url = URL(string: apiURL) else { return }
        
        do {
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                // Directory doesn't exist or API error, fall back to common files
                await downloadCommonFilesFromURL(rawBaseURL: rawBaseURL, skillName: skillName, dirName: dirName)
                return
            }
            
            // Parse the JSON response
            guard let files = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return
            }
            
            // Get the local directory
            let localDir: URL
            switch dirName {
            case "scripts":
                localDir = AppPaths.skillScriptsDirectory(name: skillName)
            case "references":
                localDir = AppPaths.skillReferencesDirectory(name: skillName)
            case "assets":
                localDir = AppPaths.skillAssetsDirectory(name: skillName)
            default:
                return
            }
            
            try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
            
            // Download each file
            for file in files {
                guard let type = file["type"] as? String,
                      type == "file",
                      let name = file["name"] as? String,
                      let downloadURL = file["download_url"] as? String,
                      let fileURL = URL(string: downloadURL) else {
                    continue
                }
                
                do {
                    let (fileData, _) = try await URLSession.shared.data(from: fileURL)
                    try fileData.write(to: localDir.appendingPathComponent(name))
                    print("SkillManager: Downloaded \(dirName)/\(name) for skill '\(skillName)'")
                } catch {
                    print("SkillManager: Failed to download \(dirName)/\(name): \(error.localizedDescription)")
                }
            }
        } catch {
            // API failed, fall back to common files approach
            await downloadCommonFilesFromURL(rawBaseURL: rawBaseURL, skillName: skillName, dirName: dirName)
        }
    }
    
    /// Fallback: try to download common files when API is unavailable
    private func downloadCommonFilesFromURL(rawBaseURL: String, skillName: String, dirName: String) async {
        let commonFiles: [String: [String]] = [
            "scripts": ["init_skill.py", "package_skill.py", "extract.py", "main.py", "run.py", "setup.py", "script.py"],
            "references": ["REFERENCE.md", "FORMS.md", "README.md", "GUIDE.md"],
            "assets": []
        ]
        
        guard let files = commonFiles[dirName] else { return }
        
        for fileName in files {
            guard let fileURL = URL(string: "\(rawBaseURL)/\(dirName)/\(fileName)") else { continue }
            
            do {
                let (data, response) = try await URLSession.shared.data(from: fileURL)
                
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    continue
                }
                
                let localDir: URL
                switch dirName {
                case "scripts":
                    localDir = AppPaths.skillScriptsDirectory(name: skillName)
                case "references":
                    localDir = AppPaths.skillReferencesDirectory(name: skillName)
                case "assets":
                    localDir = AppPaths.skillAssetsDirectory(name: skillName)
                default:
                    continue
                }
                
                try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
                try data.write(to: localDir.appendingPathComponent(fileName))
            } catch {
                // Ignore errors for optional files
            }
        }
    }
    
    // MARK: - Bootstrap Default Skills
    
    /// Key for tracking whether default skills have been bootstrapped
    private static let defaultSkillsBootstrappedKey = "defaultSkillsBootstrapped"
    
    /// Bootstrap all default Anthropic skills on first launch
    public func bootstrapDefaultSkillsIfNeeded() async {
        // Check if already bootstrapped
        guard !UserDefaults.standard.bool(forKey: Self.defaultSkillsBootstrappedKey) else {
            return
        }
        
        print("SkillManager: Bootstrapping default Anthropic skills...")
        
        var successCount = 0
        var failedSkills: [String] = []
        
        for skillName in Self.defaultAnthropicSkills {
            // Skip if already installed
            let skillPath = AppPaths.skillFilePath(name: skillName)
            if FileManager.default.fileExists(atPath: skillPath.path) {
                print("SkillManager: Skill '\(skillName)' already installed, skipping")
                successCount += 1
                continue
            }
            
            do {
                _ = try await importFromGitHub(skillName: skillName)
                print("SkillManager: Successfully imported '\(skillName)'")
                successCount += 1
            } catch {
                print("SkillManager: Failed to import '\(skillName)': \(error.localizedDescription)")
                failedSkills.append(skillName)
            }
        }
        
        // Mark as bootstrapped (even if some failed, we don't want to retry on every launch)
        UserDefaults.standard.set(true, forKey: Self.defaultSkillsBootstrappedKey)
        
        print("SkillManager: Bootstrap complete. Imported \(successCount)/\(Self.defaultAnthropicSkills.count) skills")
        if !failedSkills.isEmpty {
            print("SkillManager: Failed skills: \(failedSkills.joined(separator: ", "))")
        }
        
        // Refresh skills list
        try? await loadAllSkills()
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
    
    // MARK: - Skill Scripts
    
    /// Get the scripts directory for a skill (if it exists)
    public func scriptsDirectory(for skillName: String) -> URL? {
        let scriptsDir = AppPaths.skillScriptsDirectory(name: skillName)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: scriptsDir.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return scriptsDir
    }
    
    /// Copy skill scripts to a destination directory
    /// Creates a subdirectory for each skill: destination/skill-name/scripts/
    /// Returns the list of skill names that had scripts copied
    @discardableResult
    public func copySkillScripts(for skills: [Skill], to destinationDir: URL) throws -> [String] {
        let fm = FileManager.default
        var copiedSkills: [String] = []
        
        for skill in skills {
            guard let scriptsDir = scriptsDirectory(for: skill.name) else {
                continue
            }
            
            // Check if scripts directory has any files
            guard let contents = try? fm.contentsOfDirectory(at: scriptsDir, includingPropertiesForKeys: nil),
                  !contents.isEmpty else {
                continue
            }
            
            // Create skill scripts directory at destination: destination/skill-name/scripts/
            let skillDestDir = destinationDir
                .appendingPathComponent(skill.name, isDirectory: true)
                .appendingPathComponent("scripts", isDirectory: true)
            
            try fm.createDirectory(at: skillDestDir, withIntermediateDirectories: true)
            
            // Copy all files from scripts directory
            for fileURL in contents {
                let destURL = skillDestDir.appendingPathComponent(fileURL.lastPathComponent)
                try? fm.removeItem(at: destURL) // Remove if exists
                try fm.copyItem(at: fileURL, to: destURL)
            }
            
            copiedSkills.append(skill.name)
            print("SkillManager: Copied scripts for skill '\(skill.name)' to \(skillDestDir.path)")
        }
        
        return copiedSkills
    }
}
