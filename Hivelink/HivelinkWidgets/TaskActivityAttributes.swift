//
//  TaskActivityAttributes.swift
//  HivelinkWidgets
//
//  Duplicated ActivityAttributes for the widget extension target.
//  Must stay in sync with Hivelink/LiveActivity/TaskActivityAttributes.swift.
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
        /// 0–100 if the worker has a to-do list; nil otherwise.
        var completionPercent: Int?
        var stepCount: Int?
        var needsAttention: Bool
        var attentionMessage: String?
    }
}
