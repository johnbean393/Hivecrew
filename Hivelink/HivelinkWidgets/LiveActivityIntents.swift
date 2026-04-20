//
//  LiveActivityIntents.swift
//  HivelinkWidgets
//
//  Duplicated LiveActivityIntent types for the widget extension target.
//  Must stay in sync with Hivelink/Intents/LiveActivityIntents.swift.
//
//  The widget extension needs these type definitions to compile
//  Button(intent:) in the Live Activity views. The actual perform()
//  runs in the main app's process via AppDependencyManager.
//

import AppIntents
import Foundation

struct ApproveToolPermissionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Approve Permission"

    @Parameter(title: "Task ID")
    var taskId: String

    @Parameter(title: "Permission ID")
    var permissionId: String

    func perform() async throws -> some IntentResult {
        return .result()
    }
}

struct DenyToolPermissionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Deny Permission"

    @Parameter(title: "Task ID")
    var taskId: String

    @Parameter(title: "Permission ID")
    var permissionId: String

    func perform() async throws -> some IntentResult {
        return .result()
    }
}

struct AnswerAgentQuestionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Answer Question"

    @Parameter(title: "Task ID")
    var taskId: String

    @Parameter(title: "Question ID")
    var questionId: String

    @Parameter(title: "Answer")
    var answer: String

    func perform() async throws -> some IntentResult {
        return .result()
    }
}

struct EndHivelinkTaskIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Cancel Task"

    @Parameter(title: "Task ID")
    var taskId: String

    func perform() async throws -> some IntentResult {
        return .result()
    }
}
