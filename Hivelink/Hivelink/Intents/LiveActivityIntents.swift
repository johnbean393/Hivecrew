//
//  LiveActivityIntents.swift
//  Hivelink
//
//  App Intents conforming to LiveActivityIntent so they can be invoked
//  from Button(intent:) in the Dynamic Island and Lock Screen banner.
//

import AppIntents
import Foundation

// MARK: - Approve Tool Permission

struct ApproveToolPermissionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Approve Permission"
    static let description = IntentDescription("Approves a pending tool permission request for a task.")

    @Parameter(title: "Task ID")
    var taskId: String

    @Parameter(title: "Permission ID")
    var permissionId: String

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let service = AppDependencyManager.shared.taskService,
              let task = service.getTask(byId: taskId) else {
            return .result()
        }
        await service.respondToPermission(task, permissionId: permissionId, approved: true)
        return .result()
    }
}

// MARK: - Deny Tool Permission

struct DenyToolPermissionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Deny Permission"
    static let description = IntentDescription("Denies a pending tool permission request for a task.")

    @Parameter(title: "Task ID")
    var taskId: String

    @Parameter(title: "Permission ID")
    var permissionId: String

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let service = AppDependencyManager.shared.taskService,
              let task = service.getTask(byId: taskId) else {
            return .result()
        }
        await service.respondToPermission(task, permissionId: permissionId, approved: false)
        return .result()
    }
}

// MARK: - Answer Agent Question

struct AnswerAgentQuestionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Answer Question"
    static let description = IntentDescription("Answers a pending agent question with a suggested reply.")

    @Parameter(title: "Task ID")
    var taskId: String

    @Parameter(title: "Question ID")
    var questionId: String

    @Parameter(title: "Answer")
    var answer: String

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let service = AppDependencyManager.shared.taskService,
              let task = service.getTask(byId: taskId) else {
            return .result()
        }
        await service.answerQuestion(task, questionId: questionId, answer: answer)
        return .result()
    }
}

// MARK: - End / Cancel Task

struct EndHivelinkTaskIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Cancel Task"
    static let description = IntentDescription("Cancels a running Hivelink task.")

    @Parameter(title: "Task ID")
    var taskId: String

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let service = AppDependencyManager.shared.taskService,
              let task = service.getTask(byId: taskId) else {
            return .result()
        }
        await service.cancelTask(task)
        return .result()
    }
}
