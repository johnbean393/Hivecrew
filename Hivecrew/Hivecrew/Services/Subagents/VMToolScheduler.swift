//
//  VMToolScheduler.swift
//  Hivecrew
//
//  Serializes VM-side tool calls for subagents.
//

import Foundation

actor VMToolScheduler {
    private var tail: Task<Void, Never> = Task {}
    private var isPaused: Bool = false
    
    func setPaused(_ paused: Bool) {
        isPaused = paused
    }
    
    func run<T>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task<T, Error> {
            _ = await previous.result
            try await waitIfPaused()
            return try await operation()
        }
        tail = Task {
            _ = try? await task.value
        }
        return try await task.value
    }
    
    private func waitIfPaused() async throws {
        while isPaused {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }
}
