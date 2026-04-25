//
//  AppFocusManager.swift
//  Hivecrew
//
//  Per-app FIFO lock manager for the App Worker runtime.
//  Multiple tasks may run concurrently on different apps, but only one
//  task at a time may control a given app.  When a second task targets
//  an already-locked app it suspends until the holder releases.
//

import Foundation
import Combine

@MainActor
final class AppFocusManager: ObservableObject {
    static let shared = AppFocusManager()

    struct LockInfo: Sendable {
        let connectionId: String
        let appIdentifier: String
        let acquiredAt: Date
    }

    @Published private(set) var activeLocks: [String: LockInfo] = [:]

    private var waiters: [String: [(String, CheckedContinuation<Void, Never>)]] = [:]

    private init() {}

    /// Normalises an app identifier (bundle ID preferred, falls back to
    /// lowercased app name) so that different references to the same app
    /// resolve to the same key.
    static func normalizedKey(bundleId: String?, appName: String?) -> String {
        if let bid = bundleId, !bid.isEmpty { return bid.lowercased() }
        return (appName ?? "unknown").lowercased()
    }

    /// Acquire exclusive focus on `appKey` for `connectionId`.
    /// Returns immediately if the app is free or already held by this
    /// connection.  Suspends (FIFO) if another connection holds it.
    func acquire(appKey: String, connectionId: String) async {
        if let existing = activeLocks[appKey] {
            if existing.connectionId == connectionId { return }

            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                waiters[appKey, default: []].append((connectionId, cont))
            }
        }

        activeLocks[appKey] = LockInfo(
            connectionId: connectionId,
            appIdentifier: appKey,
            acquiredAt: Date()
        )
    }

    /// Release the lock held by `connectionId` on `appKey`.
    /// Wakes the next waiter if any.
    func release(appKey: String, connectionId: String) {
        guard let existing = activeLocks[appKey],
              existing.connectionId == connectionId else { return }

        activeLocks.removeValue(forKey: appKey)

        if var queue = waiters[appKey], !queue.isEmpty {
            let (nextId, continuation) = queue.removeFirst()
            if queue.isEmpty {
                waiters.removeValue(forKey: appKey)
            } else {
                waiters[appKey] = queue
            }
            activeLocks[appKey] = LockInfo(
                connectionId: nextId,
                appIdentifier: appKey,
                acquiredAt: Date()
            )
            continuation.resume()
        }
    }

    /// Release all locks held by a given connection (called on disconnect).
    func releaseAll(connectionId: String) {
        let ownedKeys = activeLocks.filter { $0.value.connectionId == connectionId }.map(\.key)
        for key in ownedKeys {
            release(appKey: key, connectionId: connectionId)
        }
    }

    /// Returns the number of waiters blocked on `appKey`.
    func waiterCount(for appKey: String) -> Int {
        waiters[appKey]?.count ?? 0
    }

    /// Whether `appKey` is currently locked by any connection.
    func isLocked(_ appKey: String) -> Bool {
        activeLocks[appKey] != nil
    }

    /// Snapshot of all active locks for display in the Settings UI.
    var lockSummaries: [(appKey: String, connectionId: String, waiters: Int)] {
        activeLocks.map { key, info in
            (appKey: key, connectionId: info.connectionId, waiters: waiterCount(for: key))
        }.sorted { $0.appKey < $1.appKey }
    }
}
