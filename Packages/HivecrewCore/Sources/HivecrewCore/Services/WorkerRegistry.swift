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

        let available = Self.namePool.filter { !activeNames.contains($0) }
        let name = available.randomElement() ?? "Worker-\(workers.count + 1)"

        let identity = WorkerIdentity(id: taskId, displayName: name, taskTitle: taskTitle)
        workers.append(identity)
        return identity
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
