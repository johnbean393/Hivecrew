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
        var elapsedSeconds: Int
        var stepCount: Int?
        var needsAttention: Bool
        var attentionMessage: String?
    }
}
