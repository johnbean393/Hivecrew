//
//  WorkerRegistry.swift
//  Hivecrew
//
//  Maps human-readable display names to task IDs for voice mode.
//  Session-scoped, not persisted.
//

import Foundation
import Combine

public struct WorkerIdentity: Identifiable, Equatable {
    public let id: String          // taskId
    public let displayName: String // e.g. "John"
    public let taskTitle: String   // LLM-generated short title from TaskRecord
    public var label: String { "\(displayName) · \(taskTitle)" }

    public init(id: String, displayName: String, taskTitle: String) {
        self.id = id
        self.displayName = displayName
        self.taskTitle = taskTitle
    }
}

@MainActor
public final class WorkerRegistry: ObservableObject {

    @Published public private(set) var workers: [WorkerIdentity] = []

    private static let namePool = [
        "Alex","Alice", "Ben", "Clara", "Daniel", "Elena",
        "Felix", "Grace", "Henry", "Iris", "James",
        "Kate", "Leo", "Maya", "Nathan", "Olivia", "Owen",
        "Paul", "Rosa", "Sam", "Skylar", "Tara", "Tyler", "Victor",
        "Wendy", "Zane", "Julia", "Marco", "Nadia"
    ]

    private var activeNames: Set<String> {
        Set(workers.map(\.displayName))
    }

    public init() {}

    public func assignName(for taskId: String, taskTitle: String) -> WorkerIdentity {
        if let existing = workers.first(where: { $0.id == taskId }) {
            return existing
        }

        let name = Self.stableName(for: taskId, excluding: activeNames)

        let identity = WorkerIdentity(id: taskId, displayName: name, taskTitle: taskTitle)
        workers.append(identity)
        return identity
    }

    /// Deterministic name derived from the task ID so the same task always
    /// gets the same worker name across voice sessions.
    private static func stableName(for taskId: String, excluding used: Set<String>) -> String {
        var hash = taskId.utf8.reduce(into: UInt64(0)) { h, byte in
            h = h &* 31 &+ UInt64(byte)
        }
        let poolSize = namePool.count
        let startIndex = Int(hash % UInt64(poolSize))

        for offset in 0..<poolSize {
            let candidate = namePool[(startIndex + offset) % poolSize]
            if !used.contains(candidate) {
                return candidate
            }
        }
        hash = hash &* 2_654_435_761
        return "Worker-\(hash % 10000)"
    }

    @discardableResult
    public func importExisting(taskId: String, taskTitle: String) -> WorkerIdentity {
        return assignName(for: taskId, taskTitle: taskTitle)
    }

    public func resolve(query: String) -> WorkerIdentity? {
        let lower = query.lowercased()

        if let exact = workers.first(where: { w in
            w.displayName.lowercased() == lower ||
            w.taskTitle.lowercased().contains(lower) ||
            w.id == query
        }) {
            return exact
        }

        let words = lower.split(separator: " ").map(String.init)
        if let byWord = workers.first(where: { w in
            words.contains(w.displayName.lowercased())
        }) {
            return byWord
        }

        return nil
    }

    public func deregister(taskId: String) {
        if let idx = workers.firstIndex(where: { $0.id == taskId }) {
            workers.remove(at: idx)
        }
    }

    public func clearAll() {
        workers.removeAll()
    }
}
