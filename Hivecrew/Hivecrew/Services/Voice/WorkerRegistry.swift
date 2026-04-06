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

    private var assignedNames: Set<String> = []
    private var usedNamesThisSession: Set<String> = []

    private static let namePool = [
        "Alex", "Blake", "Casey", "Dana", "Ellis",
        "Finn", "Gray", "Harper", "Indigo", "Jordan",
        "Kai", "Lane", "Morgan", "Nova", "Parker",
        "Quinn", "Riley", "Sage", "Taylor", "Val"
    ]

    func assignName(for taskId: String, role: String) -> WorkerIdentity {
        if let existing = workers.first(where: { $0.id == taskId }) {
            return existing
        }

        let name = Self.namePool.first { !usedNamesThisSession.contains($0) } ?? "Worker-\(workers.count + 1)"
        assignedNames.insert(name)
        usedNamesThisSession.insert(name)

        let identity = WorkerIdentity(id: taskId, displayName: name, role: role)
        workers.append(identity)
        return identity
    }

    func resolve(query: String) -> WorkerIdentity? {
        let lower = query.lowercased()
        return workers.first { w in
            w.displayName.lowercased() == lower ||
            w.role.lowercased().contains(lower) ||
            w.id == query
        }
    }

    func deregister(taskId: String) {
        if let idx = workers.firstIndex(where: { $0.id == taskId }) {
            let name = workers[idx].displayName
            assignedNames.remove(name)
            workers.remove(at: idx)
        }
    }

    func clearAll() {
        workers.removeAll()
        assignedNames.removeAll()
        usedNamesThisSession.removeAll()
    }
}
