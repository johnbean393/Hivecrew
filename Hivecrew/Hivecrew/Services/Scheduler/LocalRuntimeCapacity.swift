//
//  LocalRuntimeCapacity.swift
//  Hivecrew
//
//  Per-runtime slot accounting and FIFO queues for local execution.
//  Fast Worker and Isolated VM capacity are tracked independently.
//

import Foundation
import HivecrewCore

@MainActor
final class LocalRuntimeCapacity {

    struct Slot {
        var running: Set<String> = []
        var queue: [String] = []
    }

    private var slots: [AgentRuntimeKind: Slot] = [
        .fast: Slot(),
        .app: Slot(),
        .isolatedVM: Slot(),
    ]

    // MARK: - Max Slots

    func maxSlots(for kind: AgentRuntimeKind) -> Int {
        switch kind {
        case .fast:
            let stored = UserDefaults.standard.integer(forKey: "maxConcurrentFastWorkers")
            return stored > 0 ? min(max(stored, 1), 16) : 4
        case .app:
            // App Worker has no global slot limit; per-app serialization
            // is handled by AppFocusManager instead.
            return .max
        case .isolatedVM:
            return VMConcurrencyPolicy.effectiveMaxConcurrentVMs()
        }
    }

    // MARK: - Query

    func canStart(_ kind: AgentRuntimeKind) -> Bool {
        if kind == .app { return true }
        let slot = slots[kind, default: Slot()]
        return slot.running.count < maxSlots(for: kind)
    }

    func runningCount(for kind: AgentRuntimeKind) -> Int {
        slots[kind, default: Slot()].running.count
    }

    func queuedCount(for kind: AgentRuntimeKind) -> Int {
        slots[kind, default: Slot()].queue.count
    }

    // MARK: - Reserve / Release

    @discardableResult
    func reserve(_ kind: AgentRuntimeKind, taskId: String) -> Bool {
        var slot = slots[kind, default: Slot()]
        let inserted = slot.running.insert(taskId).inserted
        let queuedBefore = slot.queue.count
        slot.queue.removeAll { $0 == taskId }
        slots[kind] = slot
        return inserted || slot.queue.count != queuedBefore
    }

    @discardableResult
    func release(_ kind: AgentRuntimeKind, taskId: String) -> Bool {
        var slot = slots[kind, default: Slot()]
        let removedRunning = slot.running.remove(taskId) != nil
        let queuedBefore = slot.queue.count
        slot.queue.removeAll { $0 == taskId }
        slots[kind] = slot
        return removedRunning || slot.queue.count != queuedBefore
    }

    // MARK: - Queue

    @discardableResult
    func enqueue(_ kind: AgentRuntimeKind, taskId: String) -> Bool {
        var slot = slots[kind, default: Slot()]
        guard !slot.running.contains(taskId), !slot.queue.contains(taskId) else {
            slots[kind] = slot
            return false
        }
        slot.queue.append(taskId)
        slots[kind] = slot
        return true
    }

    func dequeueNext(_ kind: AgentRuntimeKind) -> String? {
        guard !(slots[kind, default: Slot()].queue.isEmpty) else { return nil }
        return slots[kind, default: Slot()].queue.removeFirst()
    }

    @discardableResult
    func remove(taskId: String) -> Bool {
        var changed = false
        for kind in [AgentRuntimeKind.fast, .app, .isolatedVM] {
            var slot = slots[kind, default: Slot()]
            if slot.running.remove(taskId) != nil {
                changed = true
            }
            let queuedBefore = slot.queue.count
            slot.queue.removeAll { $0 == taskId }
            if slot.queue.count != queuedBefore {
                changed = true
            }
            slots[kind] = slot
        }
        return changed
    }

    // MARK: - Snapshot

    func snapshot() -> [RuntimeCapacitySnapshot] {
        [AgentRuntimeKind.fast, .app, .isolatedVM].map { kind in
            let slot = slots[kind, default: Slot()]
            let setupStatus: RuntimeSetupStatus
            if kind == .app {
                if let req = CuaDriverManager.shared.currentSetupRequirement() {
                    switch req {
                    case .cuaDriverMissing: setupStatus = .backendMissing
                    case .appPermissionsMissing: setupStatus = .permissionsMissing
                    default: setupStatus = .unavailable
                    }
                } else {
                    setupStatus = .ready
                }
            } else {
                setupStatus = .ready
            }

            let available: Int
            if kind == .app {
                // Unlimited — per-app locks managed by AppFocusManager
                available = .max
            } else {
                available = max(0, maxSlots(for: kind) - slot.running.count)
            }

            return RuntimeCapacitySnapshot(
                runtimeKind: kind,
                supported: true,
                availableSlots: available,
                running: slot.running.count,
                queued: slot.queue.count,
                setupStatus: setupStatus
            )
        }
    }
}

// MARK: - Snapshot model

struct RuntimeCapacitySnapshot: Codable, Sendable {
    var runtimeKind: AgentRuntimeKind
    var supported: Bool
    var availableSlots: Int
    var running: Int
    var queued: Int
    var setupStatus: RuntimeSetupStatus
}

enum RuntimeSetupStatus: String, Codable, Sendable {
    case ready
    case unavailable
    case permissionsMissing
    case backendMissing
    case templateMissing
}
