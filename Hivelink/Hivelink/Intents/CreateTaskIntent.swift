//
//  CreateTaskIntent.swift
//  Hivelink
//
//  App Intent for creating a Hivelink task via Siri / Shortcuts.
//

import AppIntents
import Foundation
import HivecrewCore

struct CreateTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Create a Hivelink Task"
    static let description = IntentDescription("Creates a new task in Hivelink and dispatches it to a peer.")
    static let openAppWhenRun = false

    @Parameter(title: "Task Description")
    var taskDescription: String

    @Parameter(title: "Provider Name", default: nil)
    var providerName: String?

    @Parameter(title: "Model ID", default: nil)
    var modelId: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let taskService = AppDependencyManager.shared.taskService else {
            return .result(dialog: "Hivelink isn't ready yet. Please open the app first.")
        }

        let resolvedProvider = providerName
            ?? UserDefaults.standard.string(forKey: "hivelink.lastProviderName")
            ?? ""
        let resolvedModel = modelId
            ?? UserDefaults.standard.string(forKey: "hivelink.lastModelId")
            ?? ""

        let request = TaskCreationRequest(
            description: taskDescription,
            providerId: resolvedProvider,
            modelId: resolvedModel
        )

        let created = try await taskService.createTasks([request])
        let title = created.first?.title ?? taskDescription
        return .result(dialog: "Created task: \(title)")
    }
}
