//
//  OpenNewTaskIntent.swift
//  Hivelink
//
//  App Intent for opening the app and focusing the prompt bar.
//  Designed for Control Center widgets and Action Button.
//

import AppIntents
import Foundation

struct OpenNewTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "New Hivelink Task"
    static let description = IntentDescription("Opens Hivelink and focuses the prompt bar for a new task.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppDependencyManager.shared.setSelectedTab?(0)
        NotificationCenter.default.post(name: .focusPromptBar, object: nil)
        return .result()
    }
}
