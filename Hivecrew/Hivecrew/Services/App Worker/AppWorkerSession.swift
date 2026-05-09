//
//  AppWorkerSession.swift
//  Hivecrew
//
//  Manages the App Worker session directory layout, path validation,
//  attachment seeding, and artifact harvesting. Reuses FastWorkerPaths
//  and WorkspaceSandbox for parity with Fast Worker.
//

import Foundation
import HivecrewCore
import HivecrewShared

@MainActor
final class AppWorkerSession {

    let paths: FastWorkerPaths
    let localAccessGrants: [LocalAccessGrant]
    let sandbox: WorkspaceSandbox

    private(set) var inputFileNames: [String] = []

    init(paths: FastWorkerPaths, localAccessGrants: [LocalAccessGrant] = []) {
        self.paths = paths
        self.localAccessGrants = localAccessGrants
        self.sandbox = WorkspaceSandbox(
            root: paths.root,
            sessionDirectories: paths.allDirectories,
            grants: localAccessGrants,
            allowsHostFilesystemAccess: true
        )
    }

    // MARK: - Setup

    func initialize() throws {
        try paths.createLayout()
    }

    func seedAttachments(infos: [AttachmentInfo]) throws -> [AttachmentInfo] {
        let fm = FileManager.default
        var updated: [AttachmentInfo] = []
        for info in infos {
            let sourcePath: String
            if let copiedPath = info.copiedPath, fm.fileExists(atPath: copiedPath) {
                sourcePath = copiedPath
            } else if fm.fileExists(atPath: info.originalPath) {
                sourcePath = info.originalPath
            } else {
                continue
            }
            let sourceURL = URL(fileURLWithPath: sourcePath)
            let destURL = paths.inbox.appendingPathComponent(sourceURL.lastPathComponent)
            do {
                if fm.fileExists(atPath: destURL.path) {
                    try fm.removeItem(at: destURL)
                }
                try fm.copyItem(at: sourceURL, to: destURL)
                inputFileNames.append(sourceURL.lastPathComponent)
                updated.append(AttachmentInfo(
                    originalPath: info.originalPath,
                    copiedPath: destURL.path,
                    fileSize: info.fileSize
                ))
            } catch {
                updated.append(info)
            }
        }
        return updated
    }

    func seedSkillFiles(skills: [Skill], skillManager: SkillManager) {
        guard !skills.isEmpty else { return }
        do {
            let copied = try skillManager.copySkillFiles(for: skills, to: paths.inbox)
            for name in copied {
                inputFileNames.append(name)
            }
        } catch {
            print("AppWorkerSession: Failed to copy skill files: \(error)")
        }
    }

    // MARK: - Path Validation

    func validatePath(_ rawPath: String) throws -> URL {
        try sandbox.validatePath(rawPath)
    }

    func isPathAllowed(_ rawPath: String) -> Bool {
        sandbox.isPathAllowed(rawPath)
    }

    // MARK: - Artifact Harvesting

    func harvestArtifacts(taskTitle: String, customOutputDirectory: String?) -> [String] {
        let fm = FileManager.default

        let outboxItems = (try? fm.contentsOfDirectory(
            at: paths.outbox,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        let workspaceItems = (try? fm.contentsOfDirectory(
            at: paths.workspace,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        let outboxNames = Set(outboxItems.map(\.lastPathComponent))
        let uniqueWorkspaceItems = workspaceItems.filter { !outboxNames.contains($0.lastPathComponent) }
        let allItems = outboxItems + uniqueWorkspaceItems

        guard !allItems.isEmpty else { return [] }

        let baseOutputDirectory: URL
        if let custom = customOutputDirectory, !custom.isEmpty {
            baseOutputDirectory = URL(fileURLWithPath: custom)
        } else {
            let appSetting = UserDefaults.standard.string(forKey: "outputDirectoryPath") ?? ""
            if !appSetting.isEmpty {
                baseOutputDirectory = URL(fileURLWithPath: appSetting)
            } else {
                baseOutputDirectory = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
                    ?? URL(fileURLWithPath: NSHomeDirectory())
            }
        }

        let safeName = taskTitle
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .prefix(80)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        let timestamp = formatter.string(from: Date())
        let destDir = baseOutputDirectory.appendingPathComponent("\(safeName) \(timestamp)", isDirectory: true)

        do {
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        } catch {
            print("AppWorkerSession: Failed to create output directory: \(error)")
            return []
        }

        var outputPaths: [String] = []
        for item in allItems {
            let dest = destDir.appendingPathComponent(item.lastPathComponent)
            do {
                try fm.copyItem(at: item, to: dest)
                outputPaths.append(dest.path)
            } catch {
                print("AppWorkerSession: Failed to copy artifact \(item.lastPathComponent): \(error)")
            }
        }

        return outputPaths
    }

    func persistWorkspaceSnapshot() {
        let fm = FileManager.default
        let sessionWorkspace = AppPaths.sessionWorkspaceDirectory(id: paths.sessionId)
        do {
            try fm.createDirectory(at: sessionWorkspace, withIntermediateDirectories: true)
            let items = try fm.contentsOfDirectory(
                at: paths.workspace,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            for item in items {
                let dest = sessionWorkspace.appendingPathComponent(item.lastPathComponent)
                try fm.copyItem(at: item, to: dest)
            }
        } catch {
            print("AppWorkerSession: Failed to persist workspace snapshot: \(error)")
        }
    }

    // MARK: - Observation

    func textObservation(todoManager: TodoManager?) -> RuntimeObservation {
        var lines: [String] = []
        lines.append("Runtime: App Worker (host macOS GUI)")
        lines.append("Workspace: \(paths.workspace.path)")

        let fm = FileManager.default
        if let inboxItems = try? fm.contentsOfDirectory(atPath: paths.inbox.path),
           !inboxItems.isEmpty {
            lines.append("Inbox files: \(inboxItems.joined(separator: ", "))")
        }
        if let workspaceItems = try? fm.contentsOfDirectory(atPath: paths.workspace.path),
           !workspaceItems.isEmpty {
            lines.append("Workspace files: \(workspaceItems.joined(separator: ", "))")
        }
        if let outboxItems = try? fm.contentsOfDirectory(atPath: paths.outbox.path),
           !outboxItems.isEmpty {
            lines.append("Outbox files: \(outboxItems.joined(separator: ", "))")
        }

        if let todoList = todoManager?.getList() {
            let completed = todoList.items.filter(\.isCompleted).count
            lines.append("Todos: \(completed)/\(todoList.items.count) complete")
        }

        var metadata: [String: String] = [
            "runtime": "app",
            "workspace": paths.workspace.path,
            "inbox": paths.inbox.path,
            "outbox": paths.outbox.path
        ]
        for (i, grant) in localAccessGrants.enumerated() {
            metadata["grant_\(i)"] = grant.rootPath
        }

        return RuntimeObservation(
            text: lines.joined(separator: "\n"),
            metadata: metadata
        )
    }
}
