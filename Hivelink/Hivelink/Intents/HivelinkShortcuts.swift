//
//  HivelinkShortcuts.swift
//  Hivelink
//
//  Registers App Shortcuts so Siri can discover the intents by phrase.
//

import AppIntents

struct HivelinkShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CreateTaskIntent(),
            phrases: [
                "Create a \(.applicationName) task",
                "Ask \(.applicationName) to \(\.$taskDescription)"
            ],
            shortTitle: "Create Task",
            systemImageName: "plus.circle"
        )

        AppShortcut(
            intent: StartVoiceSessionIntent(),
            phrases: [
                "Start a \(.applicationName) call",
                "Talk to \(.applicationName)"
            ],
            shortTitle: "Start Call",
            systemImageName: "phone.fill"
        )

        AppShortcut(
            intent: GetTaskStatusIntent(),
            phrases: [
                "What's my \(.applicationName) status?",
                "Check \(.applicationName) tasks"
            ],
            shortTitle: "Task Status",
            systemImageName: "list.bullet"
        )
    }
}
