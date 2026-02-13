import Foundation
#if canImport(AppKit)
import AppKit
#endif

final class SleepWakeMonitor {
    private let onSleep: @Sendable () async -> Void
    private let onWake: @Sendable () async -> Void
#if canImport(AppKit)
    private var willSleepObserver: NSObjectProtocol?
    private var didWakeObserver: NSObjectProtocol?
#endif

    init(
        onSleep: @escaping @Sendable () async -> Void,
        onWake: @escaping @Sendable () async -> Void
    ) {
        self.onSleep = onSleep
        self.onWake = onWake
    }

    @MainActor
    func start() {
#if canImport(AppKit)
        guard willSleepObserver == nil, didWakeObserver == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        willSleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [onSleep] _ in
            Task {
                await onSleep()
            }
        }
        didWakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [onWake] _ in
            Task {
                await onWake()
            }
        }
#endif
    }

    @MainActor
    func stop() {
#if canImport(AppKit)
        let center = NSWorkspace.shared.notificationCenter
        if let willSleepObserver {
            center.removeObserver(willSleepObserver)
            self.willSleepObserver = nil
        }
        if let didWakeObserver {
            center.removeObserver(didWakeObserver)
            self.didWakeObserver = nil
        }
#endif
    }
}
