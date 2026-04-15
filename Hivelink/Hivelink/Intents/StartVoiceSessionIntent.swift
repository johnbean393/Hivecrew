//
//  StartVoiceSessionIntent.swift
//  Hivelink
//
//  App Intent for launching a voice session via Siri / Shortcuts.
//

import AppIntents
import Foundation

struct StartVoiceSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Start a Hivelink Call"
    static let description = IntentDescription("Opens Hivelink and starts a voice session.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let deps = AppDependencyManager.shared
        deps.setSelectedTab?(1)

        try? await Task.sleep(nanoseconds: 500_000_000)

        if let orchestrator = deps.voiceOrchestrator {
            orchestrator.startCall()
        }

        return .result(dialog: "Starting Hivelink voice session.")
    }
}
