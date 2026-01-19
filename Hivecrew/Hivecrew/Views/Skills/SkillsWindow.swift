//
//  SkillsWindow.swift
//  Hivecrew
//
//  Standalone window for managing Agent Skills
//

import SwiftUI
import AppKit
import HivecrewShared
import MarkdownView
import UniformTypeIdentifiers

/// Standalone window for managing Agent Skills
struct SkillsWindow: View {
    @StateObject private var skillManager = SkillManager()
    @State private var selectedSkill: Skill?
    @State private var showingImportSheet = false
    @State private var showingGitHubImport = false
    @State private var githubURL = ""
    @State private var isImporting = false
    @State private var importError: String?
    @State private var showingDeleteConfirmation = false
    @State private var skillToDelete: Skill?
    
    var body: some View {
        HSplitView {
            // Left: Skills list
            skillsList
                .frame(minWidth: 220, maxWidth: 280)
            
            // Right: Skill detail
            skillDetail
                .frame(minWidth: 400)
        }
        .frame(minWidth: 700, minHeight: 500)
        .sheet(isPresented: $showingGitHubImport) {
            githubImportSheet
        }
        .fileImporter(
            isPresented: $showingImportSheet,
            allowedContentTypes: [.folder, .plainText],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .alert("Delete Skill", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let skill = skillToDelete {
                    deleteSkill(skill)
                }
            }
        } message: {
            Text("Are you sure you want to delete '\(skillToDelete?.name ?? "")'? This cannot be undone.")
        }
        .onAppear {
            Task {
                try? await skillManager.loadAllSkills()
            }
        }
        .onChange(of: skillManager.skills) { _, newSkills in
            // Keep selectedSkill in sync with the updated skills list
            if let selected = selectedSkill,
               let updated = newSkills.first(where: { $0.name == selected.name }) {
                selectedSkill = updated
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Import from File...") {
                        showingImportSheet = true
                    }
                    Button("Import from GitHub URL...") {
                        showingGitHubImport = true
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add Skill")
            }
        }
    }
    
    // MARK: - Skills List
    
    private var skillsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Skills list
            if skillManager.skills.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("No skills installed")
                        .foregroundStyle(.secondary)
                    Text("Import skills to enhance agent capabilities")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List(skillManager.skills, selection: $selectedSkill) { skill in
                    SkillListRowView(skill: skill, skillManager: skillManager)
                        .tag(skill)
                        .contextMenu {
                            Button {
                                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: AppPaths.skillDirectory(name: skill.name).path)
                            } label: {
                                Label("Show in Finder", systemImage: "folder")
                            }
                            
                            Divider()
                            
                            Button(role: .destructive) {
                                skillToDelete = skill
                                showingDeleteConfirmation = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
                .listStyle(.inset)
            }
            
            Divider()
            
            // Footer
            HStack {
                Text("\(skillManager.skills.count) skill\(skillManager.skills.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: AppPaths.skillsDirectory.path)
                } label: {
                    Image(systemName: "folder")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Open Skills folder")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
    
    // MARK: - Skill Detail
    
    private var skillDetail: some View {
        Group {
            if let skill = selectedSkill {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Header
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(skill.name)
                                    .font(.title2)
                                    .fontWeight(.semibold)
                                
                                HStack(spacing: 8) {
                                    if skill.isImported {
                                        Label("Imported", systemImage: "arrow.down.circle")
                                            .font(.caption)
                                            .foregroundStyle(.blue)
                                    } else {
                                        Label("Extracted", systemImage: "wand.and.stars")
                                            .font(.caption)
                                            .foregroundStyle(.purple)
                                    }
                                    
                                    if let license = skill.license {
                                        Text(license)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            
                            Spacer()
                            
                            Toggle("", isOn: Binding(
                                get: { 
                                    skillManager.skills.first(where: { $0.name == skill.name })?.isEnabled ?? skill.isEnabled
                                },
                                set: { skillManager.setEnabled($0, for: skill.name) }
                            ))
                            .toggleStyle(.switch)
                        }
                        
                        Divider()
                        
                        // Description
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Description")
                                .font(.headline)
                            Text(skill.description)
                                .foregroundStyle(.secondary)
                        }
                        
                        // Allowed tools
                        if let tools = skill.allowedTools, !tools.isEmpty {
                            Divider()
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Allowed Tools")
                                    .font(.headline)
                                Text(tools)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        
                        // Compatibility
                        if let compat = skill.compatibility, !compat.isEmpty {
                            Divider()
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Compatibility")
                                    .font(.headline)
                                Text(compat)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        
                        // Instructions
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Instructions")
                                .font(.headline)
                            MarkdownView(skill.instructions)
                                .textSelection(.enabled)
                        }
                        
                        // Metadata
                        if let metadata = skill.metadata, !metadata.isEmpty {
                            Divider()
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Metadata")
                                    .font(.headline)
                                ForEach(metadata.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                                    HStack {
                                        Text(key)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text(value)
                                    }
                                    .font(.caption)
                                }
                            }
                        }
                    }
                    .padding()
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)
                    Text("Select a skill to view details")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    
    // MARK: - GitHub Import Sheet
    
    private var githubImportSheet: some View {
        VStack(spacing: 16) {
            Text("Import from GitHub")
                .font(.headline)
            
            Text("Paste the GitHub URL to the skill directory containing SKILL.md")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            TextField("https://github.com/owner/repo/tree/main/path/to/skill", text: $githubURL)
                .textFieldStyle(.roundedBorder)
            
            Text("Example: https://github.com/anthropics/skills/tree/main/skills/skill-creator")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            
            if let error = importError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
            
            HStack {
                Button("Cancel") {
                    showingGitHubImport = false
                    githubURL = ""
                    importError = nil
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button("Import") {
                    importFromGitHub()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(githubURL.isEmpty || isImporting)
            }
        }
        .padding()
        .frame(width: 500)
    }
    
    // MARK: - Actions
    
    private func importFromGitHub() {
        guard !githubURL.isEmpty else { return }
        
        isImporting = true
        importError = nil
        
        Task {
            do {
                let skill = try await skillManager.importFromGitHubURL(githubURL.trimmingCharacters(in: .whitespacesAndNewlines))
                await MainActor.run {
                    selectedSkill = skill
                    showingGitHubImport = false
                    githubURL = ""
                    isImporting = false
                }
            } catch {
                await MainActor.run {
                    importError = error.localizedDescription
                    isImporting = false
                }
            }
        }
    }
    
    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            
            Task {
                do {
                    let skill: Skill
                    if url.lastPathComponent == "SKILL.md" {
                        skill = try skillManager.importFromSkillFile(url)
                    } else {
                        skill = try skillManager.importFromLocalDirectory(url)
                    }
                    await MainActor.run {
                        selectedSkill = skill
                    }
                } catch {
                    await MainActor.run {
                        importError = error.localizedDescription
                    }
                }
            }
            
        case .failure(let error):
            importError = error.localizedDescription
        }
    }
    
    private func deleteSkill(_ skill: Skill) {
        do {
            try skillManager.deleteSkill(name: skill.name)
            if selectedSkill?.name == skill.name {
                selectedSkill = nil
            }
        } catch {
            importError = error.localizedDescription
        }
    }
}

// MARK: - Skill List Row View

struct SkillListRowView: View {
    let skill: Skill
    @ObservedObject var skillManager: SkillManager
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name)
                    .fontWeight(.medium)
                    .foregroundStyle(skill.isEnabled ? .primary : .secondary)
                
                Text(skill.description.prefix(60) + (skill.description.count > 60 ? "..." : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            
            Spacer()
            
            if !skill.isEnabled {
                Text("Off")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.2))
                    .cornerRadius(4)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    SkillsWindow()
        .frame(width: 800, height: 600)
}
