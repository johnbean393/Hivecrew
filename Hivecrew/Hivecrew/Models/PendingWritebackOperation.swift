//
//  PendingWritebackOperation.swift
//  Hivecrew
//
//  Persisted staged local writeback operations for a task.
//

import Foundation

enum WritebackOperationType: String, Codable, CaseIterable, Sendable {
    case copy
    case move
    case replaceFile = "replace_file"
}

private enum LegacyWritebackBehaviorPreference: String, Codable, Sendable {
    case directWithoutReview = "direct_without_review"
    case directFilesReviewFolders = "direct_files_review_folders"
    case reviewAll = "review_all"
}

struct WritebackAutoApplySettings: Sendable {
    static let attachmentUpdatesKey = "writebackAutoApplyAttachmentUpdates"
    static let legacyBehaviorKey = "writebackBehavior"

    static let defaults = WritebackAutoApplySettings(
        autoApplyAttachmentUpdates: false
    )

    var autoApplyAttachmentUpdates: Bool

    static func load(from defaultsStore: UserDefaults = .standard) -> WritebackAutoApplySettings {
        if hasStoredRuleValues(in: defaultsStore) {
            return WritebackAutoApplySettings(
                autoApplyAttachmentUpdates: defaultsStore.object(forKey: attachmentUpdatesKey) as? Bool ?? defaults.autoApplyAttachmentUpdates
            )
        }

        guard
            let rawValue = defaultsStore.string(forKey: legacyBehaviorKey),
            let legacyPreference = LegacyWritebackBehaviorPreference(rawValue: rawValue)
        else {
            return defaults
        }

        switch legacyPreference {
        case .directWithoutReview:
            return WritebackAutoApplySettings(autoApplyAttachmentUpdates: true)
        case .directFilesReviewFolders:
            return WritebackAutoApplySettings(autoApplyAttachmentUpdates: true)
        case .reviewAll:
            return defaults
        }
    }

    static func migrateLegacyDefaultsIfNeeded(_ defaultsStore: UserDefaults = .standard) {
        guard !hasStoredRuleValues(in: defaultsStore) else { return }

        let resolved = load(from: defaultsStore)
        defaultsStore.set(resolved.autoApplyAttachmentUpdates, forKey: attachmentUpdatesKey)
    }

    private static func hasStoredRuleValues(in defaultsStore: UserDefaults) -> Bool {
        defaultsStore.object(forKey: attachmentUpdatesKey) != nil
    }
}

struct WritebackFileFingerprint: Codable, Hashable, Sendable {
    var exists: Bool
    var isDirectory: Bool
    var fileSize: Int64?
    var modifiedAt: Date?

    static let missing = WritebackFileFingerprint(
        exists: false,
        isDirectory: false,
        fileSize: nil,
        modifiedAt: nil
    )
}

struct PendingWritebackDeletionTarget: Codable, Hashable, Sendable {
    var path: String
    var baselineFingerprint: WritebackFileFingerprint
}

struct PendingWritebackOperation: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var operationType: WritebackOperationType
    var vmSourcePath: String
    var stagedArtifactPath: String
    var destinationPath: String
    var baselineFingerprint: WritebackFileFingerprint
    var deleteOriginalTargets: [PendingWritebackDeletionTarget]
    var createdAt: Date
    var sourceFileName: String

    private enum CodingKeys: String, CodingKey {
        case id
        case operationType
        case vmSourcePath
        case stagedArtifactPath
        case destinationPath
        case baselineFingerprint
        case deleteOriginalTargets
        case createdAt
        case sourceFileName
    }

    init(
        id: UUID = UUID(),
        operationType: WritebackOperationType,
        vmSourcePath: String,
        stagedArtifactPath: String,
        destinationPath: String,
        baselineFingerprint: WritebackFileFingerprint,
        deleteOriginalTargets: [PendingWritebackDeletionTarget] = [],
        createdAt: Date = Date(),
        sourceFileName: String
    ) {
        self.id = id
        self.operationType = operationType
        self.vmSourcePath = vmSourcePath
        self.stagedArtifactPath = stagedArtifactPath
        self.destinationPath = destinationPath
        self.baselineFingerprint = baselineFingerprint
        self.deleteOriginalTargets = deleteOriginalTargets
        self.createdAt = createdAt
        self.sourceFileName = sourceFileName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        operationType = try container.decode(WritebackOperationType.self, forKey: .operationType)
        vmSourcePath = try container.decode(String.self, forKey: .vmSourcePath)
        stagedArtifactPath = try container.decode(String.self, forKey: .stagedArtifactPath)
        destinationPath = try container.decode(String.self, forKey: .destinationPath)
        baselineFingerprint = try container.decode(WritebackFileFingerprint.self, forKey: .baselineFingerprint)
        deleteOriginalTargets = try container.decodeIfPresent([PendingWritebackDeletionTarget].self, forKey: .deleteOriginalTargets) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        sourceFileName = try container.decode(String.self, forKey: .sourceFileName)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(operationType, forKey: .operationType)
        try container.encode(vmSourcePath, forKey: .vmSourcePath)
        try container.encode(stagedArtifactPath, forKey: .stagedArtifactPath)
        try container.encode(destinationPath, forKey: .destinationPath)
        try container.encode(baselineFingerprint, forKey: .baselineFingerprint)
        try container.encode(deleteOriginalTargets, forKey: .deleteOriginalTargets)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(sourceFileName, forKey: .sourceFileName)
    }

    var title: String {
        switch operationType {
        case .copy:
            return deleteOriginalTargets.isEmpty ? "Copy \(sourceFileName)" : "Copy \(sourceFileName) and remove originals"
        case .move:
            return deleteOriginalTargets.isEmpty ? "Move \(sourceFileName)" : "Move \(sourceFileName) and remove originals"
        case .replaceFile:
            return "Update \(URL(fileURLWithPath: destinationPath).lastPathComponent)"
        }
    }
}
