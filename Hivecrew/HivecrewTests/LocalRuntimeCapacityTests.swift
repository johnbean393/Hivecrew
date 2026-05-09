//
//  LocalRuntimeCapacityTests.swift
//  HivecrewTests
//
//  Tests for LocalRuntimeCapacity slot and queue management.
//

import Foundation
import Testing
import HivecrewCore
@testable import Hivecrew

@Test @MainActor
func fastSlotsIndependentOfVM() {
    let capacity = LocalRuntimeCapacity()

    // Fill VM to max
    for i in 0..<capacity.maxSlots(for: .isolatedVM) {
        capacity.reserve(.isolatedVM, taskId: "vm-\(i)")
    }
    #expect(!capacity.canStart(.isolatedVM))

    // Fast should still be available
    #expect(capacity.canStart(.fast))
    capacity.reserve(.fast, taskId: "fast-1")
    #expect(capacity.runningCount(for: .fast) == 1)
    #expect(capacity.runningCount(for: .isolatedVM) == capacity.maxSlots(for: .isolatedVM))
}

@Test @MainActor
func fastCanRunWhenVMFull() {
    let capacity = LocalRuntimeCapacity()

    for i in 0..<capacity.maxSlots(for: .isolatedVM) {
        capacity.reserve(.isolatedVM, taskId: "vm-\(i)")
    }

    #expect(capacity.canStart(.fast), "Fast Worker should be startable even when VM is at max capacity")
    capacity.reserve(.fast, taskId: "fast-task")
    #expect(capacity.runningCount(for: .fast) == 1)
}

@Test @MainActor
func releaseSlotMakesCapacityAvailable() {
    let capacity = LocalRuntimeCapacity()
    let max = capacity.maxSlots(for: .fast)

    for i in 0..<max {
        capacity.reserve(.fast, taskId: "f-\(i)")
    }
    #expect(!capacity.canStart(.fast))

    capacity.release(.fast, taskId: "f-0")
    #expect(capacity.canStart(.fast))
}

@Test @MainActor
func queueFIFOOrdering() {
    let capacity = LocalRuntimeCapacity()
    capacity.enqueue(.fast, taskId: "a")
    capacity.enqueue(.fast, taskId: "b")
    capacity.enqueue(.fast, taskId: "c")

    #expect(capacity.dequeueNext(.fast) == "a")
    #expect(capacity.dequeueNext(.fast) == "b")
    #expect(capacity.dequeueNext(.fast) == "c")
    #expect(capacity.dequeueNext(.fast) == nil)
}

@Test @MainActor
func snapshotReflectsState() {
    let capacity = LocalRuntimeCapacity()
    capacity.reserve(.fast, taskId: "f1")
    capacity.enqueue(.fast, taskId: "f2")
    capacity.reserve(.isolatedVM, taskId: "vm1")

    let snapshot = capacity.snapshot()
    let fastSnap = snapshot.first { $0.runtimeKind == .fast }
    let vmSnap = snapshot.first { $0.runtimeKind == .isolatedVM }

    #expect(fastSnap?.running == 1)
    #expect(fastSnap?.queued == 1)
    #expect(vmSnap?.running == 1)
    #expect(vmSnap?.queued == 0)
}

@Test @MainActor
func reserveRemovesTaskFromRuntimeQueue() {
    let capacity = LocalRuntimeCapacity()
    capacity.enqueue(.fast, taskId: "f1")
    capacity.enqueue(.fast, taskId: "f1")
    #expect(capacity.queuedCount(for: .fast) == 1)

    capacity.reserve(.fast, taskId: "f1")
    #expect(capacity.runningCount(for: .fast) == 1)
    #expect(capacity.queuedCount(for: .fast) == 0)
}

@Test @MainActor
func removeClearsAllRuntimeTrackingForTask() {
    let capacity = LocalRuntimeCapacity()
    capacity.reserve(.fast, taskId: "shared")
    capacity.enqueue(.app, taskId: "shared")

    capacity.remove(taskId: "shared")
    #expect(capacity.runningCount(for: .fast) == 0)
    #expect(capacity.queuedCount(for: .app) == 0)
}

// MARK: - App Worker capacity

@Test @MainActor
func appSlotsIndependentOfFastAndVM() {
    let capacity = LocalRuntimeCapacity()

    for i in 0..<capacity.maxSlots(for: .fast) {
        capacity.reserve(.fast, taskId: "fast-\(i)")
    }
    #expect(!capacity.canStart(.fast))

    for i in 0..<capacity.maxSlots(for: .isolatedVM) {
        capacity.reserve(.isolatedVM, taskId: "vm-\(i)")
    }
    #expect(!capacity.canStart(.isolatedVM))

    #expect(capacity.canStart(.app), "App Worker should be startable even when Fast and VM are full")
    capacity.reserve(.app, taskId: "app-1")
    #expect(capacity.runningCount(for: .app) == 1)
}

@Test @MainActor
func appHasUnlimitedSlots() {
    let capacity = LocalRuntimeCapacity()
    #expect(capacity.maxSlots(for: .app) == .max)
}

@Test @MainActor
func appCanAlwaysStart() {
    let capacity = LocalRuntimeCapacity()
    for i in 0..<100 {
        capacity.reserve(.app, taskId: "app-\(i)")
    }
    #expect(capacity.canStart(.app), "App Worker should always allow starting")
    #expect(capacity.runningCount(for: .app) == 100)
}

@Test @MainActor
func appReserveAndRelease() {
    let capacity = LocalRuntimeCapacity()
    capacity.reserve(.app, taskId: "app-1")
    #expect(capacity.runningCount(for: .app) == 1)

    capacity.release(.app, taskId: "app-1")
    #expect(capacity.canStart(.app))
    #expect(capacity.runningCount(for: .app) == 0)
}

@Test @MainActor
func appQueueFIFO() {
    let capacity = LocalRuntimeCapacity()
    capacity.enqueue(.app, taskId: "a")
    capacity.enqueue(.app, taskId: "b")
    capacity.enqueue(.app, taskId: "c")

    #expect(capacity.dequeueNext(.app) == "a")
    #expect(capacity.dequeueNext(.app) == "b")
    #expect(capacity.dequeueNext(.app) == "c")
    #expect(capacity.dequeueNext(.app) == nil)
}

@Test @MainActor
func snapshotIncludesApp() {
    let capacity = LocalRuntimeCapacity()
    capacity.reserve(.app, taskId: "app-1")

    let snapshot = capacity.snapshot()
    let appSnap = snapshot.first { $0.runtimeKind == .app }
    #expect(appSnap != nil)
    #expect(appSnap?.running == 1)
    #expect(appSnap?.supported == true)
}
