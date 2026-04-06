//
//  WorkerRegistry.swift
//  Hivecrew
//
//  Maps human-readable display names to task IDs for voice mode.
//  Session-scoped, not persisted.
//

import Foundation
import Combine

struct WorkerIdentity: Identifiable, Equatable {
    let id: String          // taskId
    let displayName: String // e.g. "John"
    let role: String        // e.g. "3D Modeler"
    var label: String { "\(displayName) · \(role)" }
}

@MainActor
final class WorkerRegistry: ObservableObject {

    @Published private(set) var workers: [WorkerIdentity] = []

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

    func assignName(for taskId: String, role: String) -> WorkerIdentity {
        if let existing = workers.first(where: { $0.id == taskId }) {
            return existing
        }

        let available = Self.namePool.filter { !activeNames.contains($0) }
        let name = available.randomElement() ?? "Worker-\(workers.count + 1)"

        let identity = WorkerIdentity(id: taskId, displayName: name, role: role)
        workers.append(identity)
        return identity
    }

    @discardableResult
    func importExisting(taskId: String, role: String) -> WorkerIdentity {
        return assignName(for: taskId, role: role)
    }

    func resolve(query: String) -> WorkerIdentity? {
        let lower = query.lowercased()

        if let exact = workers.first(where: { w in
            w.displayName.lowercased() == lower ||
            w.role.lowercased().contains(lower) ||
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

    func deregister(taskId: String) {
        if let idx = workers.firstIndex(where: { $0.id == taskId }) {
            workers.remove(at: idx)
        }
    }

    func clearAll() {
        workers.removeAll()
    }
}
