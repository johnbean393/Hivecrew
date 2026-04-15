//
//  StartVoiceSessionIntent.swift
//  Hivelink
//
//  App Intent for launching a voice session via Siri / Shortcuts.
//

import AppIntents
import Foundation

struct StartVoiceSessionIntent: ForegroundContinuableIntent {
    static let title: LocalizedStringResource = "Start a Hivelink Call"
    static let description = IntentDescription("Starts a voice session with Hivelink.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let deps = AppDependencyManager.shared

        if let orchestrator = deps.voiceOrchestrator {
            orchestrator.startCall()
        }

        // If the device is unlocked, bring the app to the foreground.
        // If locked, the call is already running via CallKit.
        do {
            try await requestToContinueInForeground()
            deps.setSelectedTab?(1)
        } catch {}

        return .result(dialog: "Starting Hivelink voice session.")
    }
}
