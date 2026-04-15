//
//  TaskActivityAttributes.swift
//  Hivelink
//
//  ActivityAttributes for tracking running tasks via Live Activities.
//  Shared between the main app (to request/update/end) and the widget
//  extension (to render the Dynamic Island + Lock Screen UI).
//

import ActivityKit
import Foundation

struct TaskActivityAttributes: ActivityAttributes {
    let taskId: String
    let taskTitle: String
    let peerName: String
    let createdAt: Date

    struct ContentState: Codable, Hashable {
        var status: String
        var elapsedSeconds: Int
        var stepCount: Int?
        var needsAttention: Bool
        var attentionMessage: String?
    }
}
