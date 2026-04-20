//
//  TaskActivityAttributes.swift
//  HivelinkWidgets
//
//  Duplicated ActivityAttributes for the widget extension target.
//  Must stay in sync with Hivelink/LiveActivity/TaskActivityAttributes.swift.
//

import ActivityKit
import Foundation

enum AttentionKind: String, Codable, Hashable {
    case question
    case permission
    case plan
    case writeback
}

struct TaskActivityAttributes: ActivityAttributes {
    let taskId: String
    let taskTitle: String
    let peerName: String
    let createdAt: Date

    struct ContentState: Codable, Hashable {
        var status: String
        /// 0–100 if the worker has a to-do list; nil otherwise.
        var completionPercent: Int?
        var stepCount: Int?
        var needsAttention: Bool
        var attentionMessage: String?
        var attentionKind: AttentionKind?
        /// The questionId or permissionId needed to act on the attention.
        var attentionActionId: String?
        /// Up to 2 suggested replies for agent questions, capped for width.
        var suggestedReplies: [String]?
    }
}
