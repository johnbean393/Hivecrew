//
//  MentionSuggestion.swift
//  Hivecrew
//
//  Model and provider for @mention suggestions in the prompt bar
//

import AppKit
import Combine
import Foundation
import TipKit
import UniformTypeIdentifiers
import HivecrewShared

/// A suggestion item for @mention autocomplete
struct MentionSuggestion: Identifiable, Equatable {
    
    /// The type/source of this suggestion
    enum SuggestionType: Equatable {
        case attachment
        case deliverable
        case skill
        case environmentVariable
        case injectedFile
    }
    
    let id: String
    let displayName: String
    let detail: String?
    let icon: NSImage?
    let url: URL?
    let type: SuggestionType
    
    /// For skill suggestions, the skill name
    let skillName: String?
    
    /// Initialize with a file URL (for attachments and deliverables)
    init(url: URL, type: SuggestionType) {
        self.id = url.absoluteString
        self.displayName = url.lastPathComponent
        self.detail = type == .attachment ? "Current attachment" : url.deletingLastPathComponent().path
        self.url = url
        self.type = type
        self.icon = NSWorkspace.shared.icon(forFile: url.path)
        self.skillName = nil
    }
    
    /// Initialize with a skill
    init(skill: Skill) {
        self.id = "skill:\(skill.name)"
        self.displayName = skill.name
        self.detail = String(skill.description.prefix(60)) + (skill.description.count > 60 ? "..." : "")
        self.url = nil
        self.type = .skill
        self.icon = nil
        self.skillName = skill.name
    }
    
    /// Initialize with an environment variable from VM provisioning config
    init(environmentVariable: VMProvisioningConfig.EnvironmentVariable) {
        self.id = "env:\(environmentVariable.id.uuidString)"
        self.displayName = environmentVariable.key
        self.detail = "Environment Variable"
        self.url = nil
        self.type = .environmentVariable
        self.icon = nil
        self.skillName = nil
    }
    
    /// Initialize with an injected file from VM provisioning config
    init(injectedFile: VMProvisioningConfig.FileInjection) {
        self.id = "injectedfile:\(injectedFile.id.uuidString)"
        self.displayName = injectedFile.fileName
        self.detail = injectedFile.guestPath.isEmpty ? "No VM path set" : injectedFile.guestPath
        self.type = .injectedFile
        self.skillName = nil
        
        // Resolve icon from the asset file on the host
        let assetURL = AppPaths.vmAssetsDirectory.appendingPathComponent(injectedFile.fileName)
        if FileManager.default.fileExists(atPath: assetURL.path) {
            self.url = assetURL
            self.icon = NSWorkspace.shared.icon(forFile: assetURL.path)
        } else {
            self.url = nil
            self.icon = nil
        }
    }
    
    static func == (lhs: MentionSuggestion, rhs: MentionSuggestion) -> Bool {
        lhs.id == rhs.id
    }
}

/// Provides file and skill suggestions for @mentions
/// Shows current attachments, recent deliverables, and available skills
@MainActor
final class MentionSuggestionsProvider: ObservableObject {
    
    @Published private(set) var suggestions: [MentionSuggestion] = []
    @Published private(set) var isLoading: Bool = false
    
    /// Cache of deliverable files for quick filtering
    private var deliverableSuggestions: [MentionSuggestion] = []
    
    /// Current attachment suggestions (updated via updateAttachments)
    private var attachmentSuggestions: [MentionSuggestion] = []
    
    /// Available skill suggestions
    private var skillSuggestions: [MentionSuggestion] = []
    
    /// Environment variable suggestions from VM provisioning config
    private var environmentVariableSuggestions: [MentionSuggestion] = []
    
    /// Injected file suggestions from VM provisioning config
    private var injectedFileSuggestions: [MentionSuggestion] = []
    
    /// Skill manager for loading skills
    private let skillManager = SkillManager()
    
    /// Combined suggestions for filtering (deduplicated)
    private var allSuggestions: [MentionSuggestion] {
        // Get attachment URLs to filter duplicates
        let attachmentURLs = Set(attachmentSuggestions.compactMap { $0.url })
        
        // Filter deliverables that aren't already attachments
        let filteredDeliverables = deliverableSuggestions.filter { suggestion in
            guard let url = suggestion.url else { return true }
            return !attachmentURLs.contains(url)
        }
        
        return attachmentSuggestions + filteredDeliverables + skillSuggestions + environmentVariableSuggestions + injectedFileSuggestions
    }
    
    /// The configured output directory for deliverables
    private var outputDirectory: URL {
        let outputDirectoryPath = UserDefaults.standard.string(forKey: "outputDirectoryPath") ?? ""
        if outputDirectoryPath.isEmpty {
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first 
                ?? URL(fileURLWithPath: NSHomeDirectory())
        }
        return URL(fileURLWithPath: outputDirectoryPath)
    }
    
    init() {
        loadDeliverables()
        loadSkills()
        loadProvisioningItems()
    }
    
    /// Update the current attachments to show in suggestions
    /// - Parameter attachments: The current prompt attachments
    func updateAttachments(_ attachments: [PromptAttachment]) {
        attachmentSuggestions = attachments.map { attachment in
            MentionSuggestion(url: attachment.url, type: .attachment)
        }
        updateSuggestions()
    }
    
    /// Load recent deliverable files from the output directory
    func loadDeliverables() {
        isLoading = true
        
        let directory = outputDirectory
        
        Task.detached {
            var files: [(url: URL, date: Date)] = []
            let fileManager = FileManager.default
            
            // Check if directory exists
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                await MainActor.run {
                    self.deliverableSuggestions = []
                    self.isLoading = false
                    self.updateSuggestions()
                }
                return
            }
            
            // Enumerate files in output directory (up to 2 levels deep)
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                await MainActor.run {
                    self.deliverableSuggestions = []
                    self.isLoading = false
                    self.updateSuggestions()
                }
                return
            }
            
            while let fileURL = enumerator.nextObject() as? URL {
                // Limit depth to 2 levels
                let relativePath = fileURL.path.replacingOccurrences(of: directory.path, with: "")
                let depth = relativePath.components(separatedBy: "/").count - 1
                if depth > 2 {
                    enumerator.skipDescendants()
                    continue
                }
                
                // Only include regular files
                guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                      resourceValues.isRegularFile == true else {
                    continue
                }
                
                let modDate = resourceValues.contentModificationDate ?? .distantPast
                files.append((fileURL, modDate))
            }
            
            // Sort by modification date (most recent first) and take top 50
            files.sort { $0.date > $1.date }
            let deliverables = files.prefix(50).map { 
                MentionSuggestion(url: $0.url, type: .deliverable) 
            }
            
            await MainActor.run {
                self.deliverableSuggestions = Array(deliverables)
                self.isLoading = false
                self.updateSuggestions()
                
                // Update tip state when deliverables are available
                TipStore.shared.updateDeliverablesAvailable(!self.deliverableSuggestions.isEmpty)
            }
        }
    }
    
    /// Load available skills
    func loadSkills() {
        Task {
            do {
                let skills = try await skillManager.loadAllSkills()
                await MainActor.run {
                    self.skillSuggestions = skills
                        .filter { $0.isEnabled }
                        .map { MentionSuggestion(skill: $0) }
                    self.updateSuggestions()
                }
            } catch {
                print("MentionSuggestionsProvider: Failed to load skills: \(error)")
            }
        }
    }
    
    /// Filter suggestions based on query
    /// Returns empty if query is empty (user must type at least one character after @)
    func filter(query: String) {
        guard !query.isEmpty else {
            // No suggestions for empty query - user must type at least one character
            suggestions = []
            return
        }
        
        let lowercaseQuery = query.lowercased()
        let filtered = allSuggestions.filter { suggestion in
            suggestion.displayName.lowercased().contains(lowercaseQuery)
        }
        
        suggestions = Array(filtered.prefix(8))
    }
    
    /// Load environment variables and injected files from VM provisioning config
    func loadProvisioningItems() {
        let config = VMProvisioningService.shared.config
        
        environmentVariableSuggestions = config.environmentVariables
            .filter { !$0.key.isEmpty }
            .map { MentionSuggestion(environmentVariable: $0) }
        
        injectedFileSuggestions = config.fileInjections
            .filter { !$0.fileName.isEmpty }
            .map { MentionSuggestion(injectedFile: $0) }
        
        updateSuggestions()
    }
    
    /// Refresh the deliverables, skills, and provisioning cache
    func refresh() {
        loadDeliverables()
        loadSkills()
        loadProvisioningItems()
    }
    
    /// Update displayed suggestions from current state
    private func updateSuggestions() {
        suggestions = Array(allSuggestions.prefix(8))
    }
}

/// Represents the current state of an @mention being typed
struct MentionQuery: Equatable {
    /// The query text after the @ symbol
    let query: String
    /// The range in the text where the @mention starts
    let range: NSRange
    /// The screen position for showing the popup (relative to text view)
    let position: CGPoint
    
    static func == (lhs: MentionQuery, rhs: MentionQuery) -> Bool {
        lhs.query == rhs.query && lhs.range == rhs.range
    }
}
