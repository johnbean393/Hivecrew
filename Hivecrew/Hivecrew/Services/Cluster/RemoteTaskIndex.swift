//
//  RemoteTaskIndex.swift
//  Hivecrew
//
//  Coordinator-side index mapping task IDs to the peer that owns them,
//  with cached APITask state (shadow records) for fast list aggregation.
//

import Foundation
import HivecrewAPI

actor RemoteTaskIndex {
    
    struct RemoteTaskEntry: Sendable {
        let taskId: String
        let peerId: String
        var cachedTask: APITask
    }
    
    private var entries: [String: RemoteTaskEntry] = [:]
    
    // MARK: - Registration
    
    func register(taskId: String, peerId: String, task: APITask) {
        entries[taskId] = RemoteTaskEntry(taskId: taskId, peerId: peerId, cachedTask: task)
    }
    
    func update(taskId: String, task: APITask) {
        entries[taskId]?.cachedTask = task
    }
    
    func remove(taskId: String) {
        entries.removeValue(forKey: taskId)
    }
    
    // MARK: - Lookup
    
    func peerId(for taskId: String) -> String? {
        entries[taskId]?.peerId
    }
    
    func cachedTask(for taskId: String) -> APITask? {
        entries[taskId]?.cachedTask
    }
    
    func allCachedTasks() -> [APITask] {
        entries.values.map(\.cachedTask)
    }
    
    func tasksForPeer(_ peerId: String) -> [RemoteTaskEntry] {
        entries.values.filter { $0.peerId == peerId }
    }
    
    /// Remove all entries for a peer (e.g. when it goes offline and tasks can't be tracked)
    func removeTasksForPeer(_ peerId: String) {
        let idsToRemove = entries.filter { $0.value.peerId == peerId }.map(\.key)
        for id in idsToRemove {
            entries.removeValue(forKey: id)
        }
    }
    
    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }
}
