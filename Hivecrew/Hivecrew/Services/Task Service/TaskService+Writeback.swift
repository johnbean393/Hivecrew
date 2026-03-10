//
//  TaskService+Writeback.swift
//  Hivecrew
//
//  Staged local writeback lifecycle for VM-produced artifacts.
//

import Foundation
import Combine
import SwiftData

extension TaskService {
    var writebackAutoApplySettings: WritebackAutoApplySettings {
        WritebackAutoApplySettings.load()
    }

    func listWritebackTargets(taskId: String) throws -> [LocalAccessGrant] {
        guard let task = tasks.first(where: { $0.id == taskId }) else {
            throw WritebackStagingError.applyFailed("Task '\(taskId)' was not found.")
        }
        return WritebackStagingService.shared.listTargets(for: task)
    }

    func stageWritebackOperation(
        taskId: String,
        sessionId: String,
        snapshotURL: URL,
        vmSourcePath: String,
        destinationPath: String,
        operationType: WritebackOperationType,
        deleteOriginalPaths: [String] = []
    ) throws -> PendingWritebackOperation {
        guard let task = tasks.first(where: { $0.id == taskId }) else {
            throw WritebackStagingError.applyFailed("Task '\(taskId)' was not found.")
        }

        let operation = try WritebackStagingService.shared.stageOperation(
            for: task,
            sessionId: sessionId,
            snapshotURL: snapshotURL,
            vmSourcePath: vmSourcePath,
            destinationPath: destinationPath,
            operationType: operationType,
            deleteOriginalPaths: deleteOriginalPaths
        )
        try? modelContext?.save()
        objectWillChange.send()
        return operation
    }

    func stageAttachedFileUpdate(
        taskId: String,
        sessionId: String,
        snapshotURL: URL,
        vmSourcePath: String,
        attachmentOriginalPath: String?
    ) throws -> PendingWritebackOperation {
        guard let task = tasks.first(where: { $0.id == taskId }) else {
            throw WritebackStagingError.applyFailed("Task '\(taskId)' was not found.")
        }

        let operation = try WritebackStagingService.shared.stageAttachedFileUpdate(
            for: task,
            sessionId: sessionId,
            snapshotURL: snapshotURL,
            vmSourcePath: vmSourcePath,
            attachmentOriginalPath: attachmentOriginalPath
        )
        try? modelContext?.save()
        objectWillChange.send()
        return operation
    }

    func writebackReview(for task: TaskRecord) -> WritebackReviewPayload {
        WritebackStagingService.shared.review(for: task)
    }

    func autoApplyConfiguredWriteback(for task: TaskRecord) throws -> [String] {
        let settings = writebackAutoApplySettings
        let operations = task.pendingWritebackOperations.filter { operation in
            shouldAutoApply(operation, task: task, settings: settings)
        }
        return try applyWritebackOperations(operations, for: task, summaryPrefix: "Automatically applied")
    }

    func approveWriteback(for task: TaskRecord) throws {
        let appliedPaths = try WritebackStagingService.shared.applyPending(for: task)
        task.status = .completed
        if let existing = task.resultSummary, !existing.isEmpty {
            task.resultSummary = existing + "\n\nApplied \(appliedPaths.count) staged local change(s)."
        } else {
            task.resultSummary = "Applied \(appliedPaths.count) staged local change(s)."
        }
        try? modelContext?.save()
        objectWillChange.send()
    }

    func discardWriteback(for task: TaskRecord) throws {
        try WritebackStagingService.shared.discardPending(for: task)
        task.status = .completed
        if let existing = task.resultSummary, !existing.isEmpty {
            task.resultSummary = existing + "\n\nDiscarded staged local changes."
        } else {
            task.resultSummary = "Discarded staged local changes."
        }
        try? modelContext?.save()
        objectWillChange.send()
    }

    private func applyWritebackOperations(
        _ operations: [PendingWritebackOperation],
        for task: TaskRecord,
        summaryPrefix: String
    ) throws -> [String] {
        guard !operations.isEmpty else { return [] }

        let operationIDs = Set(operations.map(\.id))
        let originalPending = task.pendingWritebackOperations
        let remaining = originalPending.filter { !operationIDs.contains($0.id) }
        let originalAppliedPaths = task.appliedWritebackPaths

        task.pendingWritebackOperations = operations

        do {
            let appliedPaths = try WritebackStagingService.shared.applyPending(for: task)
            task.pendingWritebackOperations = remaining
            appendWritebackSummary(prefix: summaryPrefix, count: appliedPaths.count, to: task)
            try? modelContext?.save()
            objectWillChange.send()
            return appliedPaths
        } catch {
            task.pendingWritebackOperations = originalPending
            task.appliedWritebackPaths = originalAppliedPaths
            throw error
        }
    }

    private func appendWritebackSummary(prefix: String, count: Int, to task: TaskRecord) {
        let sentence = "\(prefix) \(count) staged local change(s)."
        if let existing = task.resultSummary, !existing.isEmpty {
            task.resultSummary = existing + "\n\n" + sentence
        } else {
            task.resultSummary = sentence
        }
    }

    private func matchingGrant(for operation: PendingWritebackOperation, task: TaskRecord) -> LocalAccessGrant? {
        task.localAccessGrants.first { $0.allowsAccess(to: operation.destinationPath) }
    }

    private func shouldAutoApply(
        _ operation: PendingWritebackOperation,
        task: TaskRecord,
        settings: WritebackAutoApplySettings
    ) -> Bool {
        guard let grant = matchingGrant(for: operation, task: task) else {
            return false
        }

        return grant.origin == .attachment && settings.autoApplyAttachmentUpdates
    }
}
