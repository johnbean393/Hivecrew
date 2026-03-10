//
//  WritebackStagingService.swift
//  Hivecrew
//
//  Stages VM artifacts for later writeback to the local filesystem.
//

import Foundation
import HivecrewShared

struct WritebackReviewItem: Identifiable, Sendable {
    let id: UUID
    let operation: PendingWritebackOperation
    let destinationExists: Bool
    let hasConflict: Bool
    let conflictReason: String?
    let diffPreview: String?
    let stagedPreview: String?
}

struct WritebackReviewPayload: Sendable {
    let items: [WritebackReviewItem]

    var hasConflicts: Bool {
        items.contains { $0.hasConflict }
    }
}

enum WritebackStagingError: Error, LocalizedError {
    case missingSession
    case missingGrant(String)
    case invalidAttachmentDestination
    case stagedArtifactMissing(String)
    case destinationConflict(String)
    case applyFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingSession:
            return "Task session is not available for staged writeback."
        case .missingGrant(let path):
            return "No local access grant allows writes to '\(path)'."
        case .invalidAttachmentDestination:
            return "The attachment update target could not be resolved."
        case .stagedArtifactMissing(let path):
            return "The staged artifact for '\(path)' is missing."
        case .destinationConflict(let path):
            return "The destination '\(path)' changed since it was staged."
        case .applyFailed(let reason):
            return reason
        }
    }
}

@MainActor
final class WritebackStagingService {
    static let shared = WritebackStagingService()

    private let fileManager = FileManager.default

    private init() {}

    func listTargets(for task: TaskRecord) -> [LocalAccessGrant] {
        task.localAccessGrants
    }

    func stageOperation(
        for task: TaskRecord,
        sessionId: String,
        snapshotURL: URL,
        vmSourcePath: String,
        destinationPath: String,
        operationType: WritebackOperationType,
        deleteOriginalPaths: [String] = []
    ) throws -> PendingWritebackOperation {
        let matchingGrant = try requireGrant(for: destinationPath, task: task)
        _ = matchingGrant
        let deleteOriginalTargets = try buildDeleteTargets(
            for: deleteOriginalPaths,
            task: task,
            currentDestinationPath: destinationPath
        )

        let stagedArtifactURL = try persistSnapshot(
            sessionId: sessionId,
            snapshotURL: snapshotURL,
            preferredFileName: snapshotURL.lastPathComponent
        )

        let baselineFingerprint = fingerprint(atPath: destinationPath)
        let operation = PendingWritebackOperation(
            operationType: operationType,
            vmSourcePath: vmSourcePath,
            stagedArtifactPath: stagedArtifactURL.path,
            destinationPath: destinationPath,
            baselineFingerprint: baselineFingerprint,
            deleteOriginalTargets: deleteOriginalTargets,
            sourceFileName: snapshotURL.lastPathComponent
        )

        var updatedOperations = task.pendingWritebackOperations
        if let existingIndex = updatedOperations.firstIndex(where: { $0.destinationPath == destinationPath }) {
            let existing = updatedOperations.remove(at: existingIndex)
            try? removeStagedArtifact(for: existing)
        }
        updatedOperations.append(operation)
        task.pendingWritebackOperations = updatedOperations
        return operation
    }

    func stageAttachedFileUpdate(
        for task: TaskRecord,
        sessionId: String,
        snapshotURL: URL,
        vmSourcePath: String,
        attachmentOriginalPath: String?
    ) throws -> PendingWritebackOperation {
        let destinationPath: String
        if let attachmentOriginalPath, !attachmentOriginalPath.isEmpty {
            destinationPath = attachmentOriginalPath
        } else if let firstAttachmentPath = task.attachmentInfos.first?.originalPath {
            destinationPath = firstAttachmentPath
        } else {
            throw WritebackStagingError.invalidAttachmentDestination
        }

        return try stageOperation(
            for: task,
            sessionId: sessionId,
            snapshotURL: snapshotURL,
            vmSourcePath: vmSourcePath,
            destinationPath: destinationPath,
            operationType: .replaceFile
        )
    }

    func review(for task: TaskRecord) -> WritebackReviewPayload {
        let items = task.pendingWritebackOperations.map { operation in
            buildReviewItem(for: operation)
        }
        return WritebackReviewPayload(items: items)
    }

    func applyPending(for task: TaskRecord) throws -> [String] {
        let review = review(for: task)
        if let conflict = review.items.first(where: { $0.hasConflict }) {
            throw WritebackStagingError.destinationConflict(conflict.operation.destinationPath)
        }

        var appliedPaths: [String] = []

        for operation in task.pendingWritebackOperations {
            let artifactURL = URL(fileURLWithPath: operation.stagedArtifactPath)
            guard fileManager.fileExists(atPath: artifactURL.path) else {
                throw WritebackStagingError.stagedArtifactMissing(operation.destinationPath)
            }

            let destinationURL = URL(fileURLWithPath: operation.destinationPath)
            guard let grant = task.localAccessGrants.first(where: { $0.allowsAccess(to: destinationURL.path) }) else {
                throw WritebackStagingError.missingGrant(destinationURL.path)
            }

            try withScopedAccess(for: grant) {
                let parentURL = destinationURL.deletingLastPathComponent()
                try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true, attributes: nil)
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                try fileManager.copyItem(at: artifactURL, to: destinationURL)
            }

            appliedPaths.append(destinationURL.path)
        }

        for operation in task.pendingWritebackOperations {
            for deleteTarget in operation.deleteOriginalTargets {
                let deleteURL = URL(fileURLWithPath: deleteTarget.path)
                guard let grant = task.localAccessGrants.first(where: { $0.allowsAccess(to: deleteURL.path) }) else {
                    throw WritebackStagingError.missingGrant(deleteURL.path)
                }

                try withScopedAccess(for: grant) {
                    guard fileManager.fileExists(atPath: deleteURL.path) else { return }
                    try fileManager.removeItem(at: deleteURL)
                }
            }
        }

        try discardPending(for: task)
        let mergedPaths = Set(task.appliedWritebackPaths ?? []).union(appliedPaths)
        task.appliedWritebackPaths = mergedPaths.sorted()
        return appliedPaths.sorted()
    }

    func discardPending(for task: TaskRecord) throws {
        for operation in task.pendingWritebackOperations {
            try? removeStagedArtifact(for: operation)
        }
        task.pendingWritebackOperations = []
    }

    private func requireGrant(for destinationPath: String, task: TaskRecord) throws -> LocalAccessGrant {
        guard let grant = task.localAccessGrants.first(where: { $0.allowsAccess(to: destinationPath) }) else {
            throw WritebackStagingError.missingGrant(destinationPath)
        }
        return grant
    }

    private func persistSnapshot(sessionId: String, snapshotURL: URL, preferredFileName: String) throws -> URL {
        let artifactsDirectory = AppPaths.sessionWritebackArtifactsDirectory(id: sessionId)
        try fileManager.createDirectory(at: artifactsDirectory, withIntermediateDirectories: true, attributes: nil)

        let destinationURL = uniqueArtifactURL(
            in: artifactsDirectory,
            preferredFileName: preferredFileName
        )

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: snapshotURL, to: destinationURL)
        return destinationURL
    }

    private func removeStagedArtifact(for operation: PendingWritebackOperation) throws {
        let url = URL(fileURLWithPath: operation.stagedArtifactPath)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func uniqueArtifactURL(in directory: URL, preferredFileName: String) -> URL {
        let baseName = (preferredFileName as NSString).deletingPathExtension
        let ext = (preferredFileName as NSString).pathExtension
        let candidate = directory.appendingPathComponent(preferredFileName)
        if !fileManager.fileExists(atPath: candidate.path) {
            return candidate
        }

        let suffix = UUID().uuidString.prefix(8)
        let fileName = ext.isEmpty
            ? "\(baseName)-\(suffix)"
            : "\(baseName)-\(suffix).\(ext)"
        return directory.appendingPathComponent(fileName)
    }

    private func buildReviewItem(for operation: PendingWritebackOperation) -> WritebackReviewItem {
        let currentFingerprint = fingerprint(atPath: operation.destinationPath)
        let deleteConflicts = operation.deleteOriginalTargets.filter { target in
            fingerprint(atPath: target.path) != target.baselineFingerprint
        }
        let hasConflict = currentFingerprint != operation.baselineFingerprint || !deleteConflicts.isEmpty

        let artifactURL = URL(fileURLWithPath: operation.stagedArtifactPath)
        let diffPreview: String?
        if operation.operationType == .replaceFile,
           currentFingerprint.exists,
           isTextPreviewSupported(url: artifactURL),
           isTextPreviewSupported(url: URL(fileURLWithPath: operation.destinationPath)) {
            diffPreview = unifiedDiff(
                originalURL: URL(fileURLWithPath: operation.destinationPath),
                updatedURL: artifactURL
            )
        } else {
            diffPreview = nil
        }

        let stagedPreview = textPreview(at: artifactURL)
        let conflictReason: String?
        if currentFingerprint != operation.baselineFingerprint {
            conflictReason = "Destination changed after staging."
        } else if let firstDeleteConflict = deleteConflicts.first {
            conflictReason = "Original item changed after staging: \(firstDeleteConflict.path)"
        } else {
            conflictReason = nil
        }

        return WritebackReviewItem(
            id: operation.id,
            operation: operation,
            destinationExists: currentFingerprint.exists,
            hasConflict: hasConflict,
            conflictReason: conflictReason,
            diffPreview: diffPreview,
            stagedPreview: stagedPreview
        )
    }

    private func buildDeleteTargets(
        for paths: [String],
        task: TaskRecord,
        currentDestinationPath: String
    ) throws -> [PendingWritebackDeletionTarget] {
        let normalizedPaths = Array(
            Set(
                paths
                    .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
                    .filter { !$0.isEmpty }
            )
        ).sorted()

        return try normalizedPaths.map { path in
            if URL(fileURLWithPath: currentDestinationPath).standardizedFileURL.path == path {
                throw WritebackStagingError.applyFailed("Cannot delete '\(path)' because it is also the staged writeback destination.")
            }
            if task.pendingWritebackOperations.contains(where: { URL(fileURLWithPath: $0.destinationPath).standardizedFileURL.path == path }) {
                throw WritebackStagingError.applyFailed("Cannot delete '\(path)' because it is also a staged writeback destination.")
            }
            _ = try requireGrant(for: path, task: task)
            return PendingWritebackDeletionTarget(
                path: path,
                baselineFingerprint: fingerprint(atPath: path)
            )
        }
    }

    func fingerprint(atPath path: String) -> WritebackFileFingerprint {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .missing
        }

        let attributes = try? fileManager.attributesOfItem(atPath: path)
        let fileSize = attributes?[.size] as? Int64
        let modifiedAt = attributes?[.modificationDate] as? Date

        return WritebackFileFingerprint(
            exists: true,
            isDirectory: isDirectory.boolValue,
            fileSize: fileSize,
            modifiedAt: modifiedAt
        )
    }

    private func withScopedAccess<T>(for grant: LocalAccessGrant, body: () throws -> T) throws -> T {
        if let bookmarkData = grant.bookmarkData {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            return try body()
        }
        return try body()
    }

    private func isTextPreviewSupported(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return [
            "txt", "md", "markdown", "json", "yaml", "yml", "toml", "xml", "html", "css",
            "js", "ts", "tsx", "jsx", "swift", "py", "rb", "go", "rs", "java", "kt",
            "sh", "zsh", "bash", "csv", "sql", "plist"
        ].contains(ext)
    }

    private func textPreview(at url: URL) -> String? {
        guard isTextPreviewSupported(url: url) else { return nil }
        guard let data = try? Data(contentsOf: url), data.count <= 512_000 else { return nil }
        guard let content = String(data: data, encoding: .utf8) else { return nil }
        return String(content.prefix(4_000))
    }

    private func unifiedDiff(originalURL: URL, updatedURL: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/diff")
        process.arguments = ["-u", originalURL.path, updatedURL.path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard !data.isEmpty else { return nil }
            let output = String(data: data, encoding: .utf8) ?? ""
            return String(output.prefix(12_000))
        } catch {
            return nil
        }
    }
}
