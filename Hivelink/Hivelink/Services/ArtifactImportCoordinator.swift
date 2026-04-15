//
//  ArtifactImportCoordinator.swift
//  Hivelink
//
//  Manages downloading and storing remote task artifacts (trace bundles, output files)
//  with lazy import for older tasks and periodic cache cleanup.
//

import Combine
import Foundation
import HivecrewAPIModels
import HivecrewCore
import HivecrewShared

@MainActor
final class ArtifactImportCoordinator: ObservableObject {

    /// Tasks currently being imported (prevents duplicate work).
    private var activeImports: Set<String> = []

    /// Last error encountered during import, for display in the UI.
    @Published var lastImportError: String?

    private static let outputsDirectoryName = "outputs"
    private static let recentImportLimit = 20

    // MARK: - Path helpers

    static var outputsDirectory: URL {
        let url = AppPaths.appSupportDirectory.appendingPathComponent(outputsDirectoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func outputDirectory(for taskId: String) -> URL {
        outputsDirectory.appendingPathComponent(taskId, isDirectory: true)
    }

    func sessionDirectoryURL(for task: TaskRecord) -> URL? {
        guard let sid = task.sessionId, !sid.isEmpty else { return nil }
        return AppPaths.sessionDirectory(id: sid)
    }

    func hasImportedTrace(for task: TaskRecord) -> Bool {
        guard let dir = sessionDirectoryURL(for: task) else { return false }
        return RemoteExecutionArtifactImporter.traceJsonlExists(in: dir)
    }

    // MARK: - Core import

    /// Downloads trace bundle and output files for a completed remote task.
    /// Updates the TaskRecord's `sessionId` and `outputFilePaths` in place.
    /// Returns `true` on success.
    @discardableResult
    func importArtifacts(
        task: TaskRecord,
        peer: RemoteClusterPeer,
        workerTaskId: String,
        remoteTask: APITask,
        client: PeerAPIClient
    ) async -> Bool {
        guard !activeImports.contains(task.id) else { return false }
        activeImports.insert(task.id)
        defer { activeImports.remove(task.id) }

        let sessionId = task.sessionId ?? UUID().uuidString
        let sessionDir = AppPaths.sessionDirectory(id: sessionId)
        let fm = FileManager.default

        do {
            try fm.createDirectory(at: sessionDir, withIntermediateDirectories: true)

            try await RemoteExecutionArtifactImporter.downloadTraceBundleToSessionDirectory(
                client: client,
                workerTaskId: workerTaskId,
                canonicalTaskId: task.id,
                sessionDirectory: sessionDir
            )

            guard RemoteExecutionArtifactImporter.traceJsonlExists(in: sessionDir) else {
                lastImportError = "Peer returned an empty trace bundle. The trace may not be ready yet."
                return false
            }

            let outputFiles = try await RemoteExecutionArtifactImporter.downloadRemoteOutputFiles(
                client: client,
                workerTaskId: workerTaskId,
                canonicalTaskId: task.id,
                remoteTaskSnapshot: remoteTask
            )

            var writtenPaths: [String] = []
            if !outputFiles.isEmpty {
                let outDir = Self.outputDirectory(for: task.id)
                try fm.createDirectory(at: outDir, withIntermediateDirectories: true)

                for file in outputFiles {
                    let dest = outDir.appendingPathComponent(file.name)
                    try file.data.write(to: dest, options: .atomic)
                    writtenPaths.append(dest.path)
                }
            }

            task.sessionId = sessionId
            if !writtenPaths.isEmpty {
                task.outputFilePaths = writtenPaths
            }
            lastImportError = nil
            return true
        } catch {
            lastImportError = error.localizedDescription
            return false
        }
    }

    // MARK: - Lazy import

    /// Imports artifacts for the most recent completed tasks that haven't been imported yet.
    /// Called after task list refreshes to eagerly populate recent history.
    func importRecentCompleted(
        tasks: [TaskRecord],
        peerClient: @escaping (RemoteClusterPeer) async -> PeerAPIClient,
        peerLookup: @escaping (String) async -> RemoteClusterPeer?,
        remoteTaskIndex: RemoteTaskIndex,
        saveContext: @escaping () throws -> Void
    ) async {
        let terminalStatuses: Set<TaskStatus> = [.completed, .failed, .cancelled, .timedOut, .maxIterations, .planFailed]
        let candidates = tasks
            .filter { terminalStatuses.contains($0.status) && $0.sessionId == nil && $0.wasExecutedRemotely }
            .sorted { ($0.completedAt ?? $0.createdAt) > ($1.completedAt ?? $1.createdAt) }
            .prefix(Self.recentImportLimit)

        for task in candidates {
            guard let peerId = await remoteTaskIndex.peerId(for: task.id),
                  let workerTaskId = await remoteTaskIndex.workerTaskId(for: task.id),
                  let cachedTask = await remoteTaskIndex.cachedTask(for: task.id),
                  let peer = await peerLookup(peerId) else { continue }

            let client = await peerClient(peer)
            let success = await importArtifacts(
                task: task,
                peer: peer,
                workerTaskId: workerTaskId,
                remoteTask: cachedTask,
                client: client
            )
            if success {
                try? saveContext()
            }
        }
    }

    /// On-demand import for a single task (when user opens a completed task that hasn't been imported yet).
    func importOnDemand(
        task: TaskRecord,
        peerClient: @escaping (RemoteClusterPeer) async -> PeerAPIClient,
        peerLookup: @escaping (String) async -> RemoteClusterPeer?,
        remoteTaskIndex: RemoteTaskIndex,
        saveContext: @escaping () throws -> Void
    ) async -> Bool {
        guard task.sessionId == nil || !hasImportedTrace(for: task) else { return true }

        // Primary path: use the remote task index
        if let peerId = await remoteTaskIndex.peerId(for: task.id),
           let workerTaskId = await remoteTaskIndex.workerTaskId(for: task.id),
           let cachedTask = await remoteTaskIndex.cachedTask(for: task.id),
           let peer = await peerLookup(peerId) {
            let client = await peerClient(peer)
            let success = await importArtifacts(
                task: task,
                peer: peer,
                workerTaskId: workerTaskId,
                remoteTask: cachedTask,
                client: client
            )
            if success { try? saveContext() }
            return success
        }

        // Fallback: the index entry may have been prematurely cleared;
        // reconstruct from the task's persisted cluster fields.
        if let peerId = task.clusterPeerId, !peerId.isEmpty,
           let workerTaskId = task.clusterWorkerTaskId, !workerTaskId.isEmpty,
           let peer = await peerLookup(peerId) {
            let client = await peerClient(peer)
            let remoteTask: APITask
            do {
                remoteTask = try await client.getTask(id: workerTaskId)
            } catch {
                lastImportError = "Could not reach peer: \(error.localizedDescription)"
                return false
            }
            let success = await importArtifacts(
                task: task,
                peer: peer,
                workerTaskId: workerTaskId,
                remoteTask: remoteTask,
                client: client
            )
            if success { try? saveContext() }
            return success
        }

        lastImportError = "No peer connection information available for this task."
        return false
    }

    // MARK: - Cache cleanup

    /// Removes session directories older than `days` and orphaned output directories.
    func clearCache(olderThan days: Int = 30, knownTaskIds: Set<String> = []) {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)

        if let sessionContents = try? fm.contentsOfDirectory(
            at: AppPaths.sessionsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) {
            for dir in sessionContents {
                guard let values = try? dir.resourceValues(forKeys: [.contentModificationDateKey]),
                      let modified = values.contentModificationDate,
                      modified < cutoff else { continue }
                try? fm.removeItem(at: dir)
            }
        }

        if !knownTaskIds.isEmpty,
           let outputContents = try? fm.contentsOfDirectory(
            at: Self.outputsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
           ) {
            for dir in outputContents {
                let taskId = dir.lastPathComponent
                guard let values = try? dir.resourceValues(forKeys: [.contentModificationDateKey]),
                      let modified = values.contentModificationDate,
                      modified < cutoff,
                      !knownTaskIds.contains(taskId) else { continue }
                try? fm.removeItem(at: dir)
            }
        }
    }
}
