//
//  PendingWritebackOperation.swift
//  Hivecrew
//
//  Persisted staged local writeback operations for a task.
//

import Foundation

public enum WritebackOperationType: String, Codable, CaseIterable, Sendable {
    case copy
    case move
    case replaceFile = "replace_file"
}

private enum LegacyWritebackBehaviorPreference: String, Codable, Sendable {
    case directWithoutReview = "direct_without_review"
    case directFilesReviewFolders = "direct_files_review_folders"
    case reviewAll = "review_all"
}

public struct WritebackAutoApplySettings: Sendable {
    public static let attachmentUpdatesKey = "writebackAutoApplyAttachmentUpdates"
    public static let legacyBehaviorKey = "writebackBehavior"

    public static let defaults = WritebackAutoApplySettings(
        autoApplyAttachmentUpdates: false
    )

    public var autoApplyAttachmentUpdates: Bool

    public init(autoApplyAttachmentUpdates: Bool) {
        self.autoApplyAttachmentUpdates = autoApplyAttachmentUpdates
    }

    public static func load(from defaultsStore: UserDefaults = .standard) -> WritebackAutoApplySettings {
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

    public static func migrateLegacyDefaultsIfNeeded(_ defaultsStore: UserDefaults = .standard) {
        guard !hasStoredRuleValues(in: defaultsStore) else { return }

        let resolved = load(from: defaultsStore)
        defaultsStore.set(resolved.autoApplyAttachmentUpdates, forKey: attachmentUpdatesKey)
    }

    public static func hasStoredRuleValues(in defaultsStore: UserDefaults) -> Bool {
        defaultsStore.object(forKey: attachmentUpdatesKey) != nil
    }
}

public struct WritebackFileFingerprint: Codable, Hashable, Sendable {
    public var exists: Bool
    public var isDirectory: Bool
    public var fileSize: Int64?
    public var modifiedAt: Date?

    public static let missing = WritebackFileFingerprint(
        exists: false,
        isDirectory: false,
        fileSize: nil,
        modifiedAt: nil
    )

    public init(exists: Bool, isDirectory: Bool, fileSize: Int64?, modifiedAt: Date?) {
        self.exists = exists
        self.isDirectory = isDirectory
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
    }
}

public struct PendingWritebackDeletionTarget: Codable, Hashable, Sendable {
    public var path: String
    public var baselineFingerprint: WritebackFileFingerprint

    public init(path: String, baselineFingerprint: WritebackFileFingerprint) {
        self.path = path
        self.baselineFingerprint = baselineFingerprint
    }
}

public struct PendingWritebackOperation: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var operationType: WritebackOperationType
    public var vmSourcePath: String
    public var stagedArtifactPath: String
    public var destinationPath: String
    public var baselineFingerprint: WritebackFileFingerprint
    public var deleteOriginalTargets: [PendingWritebackDeletionTarget]
    public var createdAt: Date
    public var sourceFileName: String

    public enum CodingKeys: String, CodingKey {
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

    public init(
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

    public init(from decoder: Decoder) throws {
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

    public func encode(to encoder: Encoder) throws {
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

    public var title: String {
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
