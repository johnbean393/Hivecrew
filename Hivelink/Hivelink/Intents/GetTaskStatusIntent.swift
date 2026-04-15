//
//  GetTaskStatusIntent.swift
//  Hivelink
//
//  App Intent for querying current task status via Siri / Shortcuts.
//

import AppIntents
import Foundation

struct GetTaskStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Hivelink Status"
    static let description = IntentDescription("Returns a summary of active Hivelink tasks.")
    static let openAppWhenRun = false

    @Parameter(title: "Task Name", default: nil)
    var taskName: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let summaries = SharedDataReader.taskSummaries()

        if let name = taskName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            let lowered = name.lowercased()
            let matched = summaries.filter { $0.title.lowercased().contains(lowered) }
            if matched.isEmpty {
                return .result(dialog: "No tasks matching \"\(name)\" found.")
            }
            let lines = matched.map { "\($0.title) — \($0.statusName)" }
            return .result(dialog: "\(IntentDialog(stringLiteral: lines.joined(separator: "\n")))")
        }

        let active = summaries.filter(\.isActive)
        if active.isEmpty {
            return .result(dialog: "No active tasks right now.")
        }

        let header = active.count == 1 ? "1 active task:" : "\(active.count) active tasks:"
        let lines = active.prefix(5).map { "• \($0.title) — \($0.statusName)" }
        let suffix = active.count > 5 ? "\n…and \(active.count - 5) more" : ""
        let summary = header + "\n" + lines.joined(separator: "\n") + suffix
        return .result(dialog: "\(IntentDialog(stringLiteral: summary))")
    }
}
