//
//  RemoteTaskIndex.swift
//  Hivecrew
//
//  Owner-side index mapping canonical task IDs to leased executor tasks,
//  with cached APITask state for fast aggregation and reconciliation.
//

import Foundation
import HivecrewAPIModels

public actor RemoteTaskIndex {

    public struct RemoteTaskEntry: Sendable {
        public let canonicalTaskId: String
        public let peerId: String
        public let workerTaskId: String
        public var cachedTask: APITask

        public init(canonicalTaskId: String, peerId: String, workerTaskId: String, cachedTask: APITask) {
            self.canonicalTaskId = canonicalTaskId
            self.peerId = peerId
            self.workerTaskId = workerTaskId
            self.cachedTask = cachedTask
        }
    }

    private var entriesByCanonicalTaskId: [String: RemoteTaskEntry] = [:]
    private var canonicalTaskIdByWorkerTaskKey: [String: String] = [:]

    public init() {}

    // MARK: - Registration

    public func register(canonicalTaskId: String, peerId: String, workerTaskId: String, task: APITask) {
        let entry = RemoteTaskEntry(
            canonicalTaskId: canonicalTaskId,
            peerId: peerId,
            workerTaskId: workerTaskId,
            cachedTask: task
        )
        entriesByCanonicalTaskId[canonicalTaskId] = entry
        canonicalTaskIdByWorkerTaskKey[workerTaskKey(peerId: peerId, workerTaskId: workerTaskId)] = canonicalTaskId
    }

    public func update(canonicalTaskId: String, task: APITask) {
        entriesByCanonicalTaskId[canonicalTaskId]?.cachedTask = task
    }

    public func remove(canonicalTaskId: String) {
        guard let removed = entriesByCanonicalTaskId.removeValue(forKey: canonicalTaskId) else { return }
        canonicalTaskIdByWorkerTaskKey.removeValue(
            forKey: workerTaskKey(peerId: removed.peerId, workerTaskId: removed.workerTaskId)
        )
    }

    // MARK: - Lookup

    public func peerId(for canonicalTaskId: String) -> String? {
        entriesByCanonicalTaskId[canonicalTaskId]?.peerId
    }

    public func workerTaskId(for canonicalTaskId: String) -> String? {
        entriesByCanonicalTaskId[canonicalTaskId]?.workerTaskId
    }

    public func cachedTask(for canonicalTaskId: String) -> APITask? {
        entriesByCanonicalTaskId[canonicalTaskId]?.cachedTask
    }

    public func canonicalTaskId(peerId: String, workerTaskId: String) -> String? {
        canonicalTaskIdByWorkerTaskKey[workerTaskKey(peerId: peerId, workerTaskId: workerTaskId)]
    }

    public func tasksForPeer(_ peerId: String) -> [RemoteTaskEntry] {
        entriesByCanonicalTaskId.values.filter { $0.peerId == peerId }
    }

    public func allEntries() -> [RemoteTaskEntry] {
        Array(entriesByCanonicalTaskId.values)
    }

    /// Remove all entries for a peer (e.g. when it goes offline and tasks can't be tracked)
    public func removeTasksForPeer(_ peerId: String) {
        let idsToRemove = entriesByCanonicalTaskId.filter { $0.value.peerId == peerId }.map(\.key)
        for id in idsToRemove {
            remove(canonicalTaskId: id)
        }
    }

    public var count: Int { entriesByCanonicalTaskId.count }
    public var isEmpty: Bool { entriesByCanonicalTaskId.isEmpty }

    private func workerTaskKey(peerId: String, workerTaskId: String) -> String {
        "\(peerId)::\(workerTaskId)"
    }
}
