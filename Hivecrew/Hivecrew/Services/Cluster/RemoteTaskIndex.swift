//
//  RemoteTaskIndex.swift
//  Hivecrew
//
//  Owner-side index mapping canonical task IDs to leased executor tasks,
//  with cached APITask state for fast aggregation and reconciliation.
//

import Foundation
import HivecrewAPI

actor RemoteTaskIndex {
    
    struct RemoteTaskEntry: Sendable {
        let canonicalTaskId: String
        let peerId: String
        let workerTaskId: String
        var cachedTask: APITask
    }
    
    private var entriesByCanonicalTaskId: [String: RemoteTaskEntry] = [:]
    private var canonicalTaskIdByWorkerTaskKey: [String: String] = [:]
    
    // MARK: - Registration
    
    func register(canonicalTaskId: String, peerId: String, workerTaskId: String, task: APITask) {
        let entry = RemoteTaskEntry(
            canonicalTaskId: canonicalTaskId,
            peerId: peerId,
            workerTaskId: workerTaskId,
            cachedTask: task
        )
        entriesByCanonicalTaskId[canonicalTaskId] = entry
        canonicalTaskIdByWorkerTaskKey[workerTaskKey(peerId: peerId, workerTaskId: workerTaskId)] = canonicalTaskId
    }
    
    func update(canonicalTaskId: String, task: APITask) {
        entriesByCanonicalTaskId[canonicalTaskId]?.cachedTask = task
    }
    
    func remove(canonicalTaskId: String) {
        guard let removed = entriesByCanonicalTaskId.removeValue(forKey: canonicalTaskId) else { return }
        canonicalTaskIdByWorkerTaskKey.removeValue(
            forKey: workerTaskKey(peerId: removed.peerId, workerTaskId: removed.workerTaskId)
        )
    }
    
    // MARK: - Lookup
    
    func peerId(for canonicalTaskId: String) -> String? {
        entriesByCanonicalTaskId[canonicalTaskId]?.peerId
    }
    
    func workerTaskId(for canonicalTaskId: String) -> String? {
        entriesByCanonicalTaskId[canonicalTaskId]?.workerTaskId
    }
    
    func cachedTask(for canonicalTaskId: String) -> APITask? {
        entriesByCanonicalTaskId[canonicalTaskId]?.cachedTask
    }
    
    func canonicalTaskId(peerId: String, workerTaskId: String) -> String? {
        canonicalTaskIdByWorkerTaskKey[workerTaskKey(peerId: peerId, workerTaskId: workerTaskId)]
    }

    func tasksForPeer(_ peerId: String) -> [RemoteTaskEntry] {
        entriesByCanonicalTaskId.values.filter { $0.peerId == peerId }
    }

    func allEntries() -> [RemoteTaskEntry] {
        Array(entriesByCanonicalTaskId.values)
    }
    
    /// Remove all entries for a peer (e.g. when it goes offline and tasks can't be tracked)
    func removeTasksForPeer(_ peerId: String) {
        let idsToRemove = entriesByCanonicalTaskId.filter { $0.value.peerId == peerId }.map(\.key)
        for id in idsToRemove {
            remove(canonicalTaskId: id)
        }
    }
    
    var count: Int { entriesByCanonicalTaskId.count }
    var isEmpty: Bool { entriesByCanonicalTaskId.isEmpty }
    
    private func workerTaskKey(peerId: String, workerTaskId: String) -> String {
        "\(peerId)::\(workerTaskId)"
    }
}
