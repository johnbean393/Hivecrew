//
//  IncomingCallContext.swift
//  Hivelink
//

import Foundation

struct IncomingCallContext: Sendable {
    enum TriggerEvent: String, Sendable, Codable {
        case question, permission, completed, failed
        case planReady, writebackReady, allTasksDone
    }

    let trigger: TriggerEvent
    let taskId: String
    let workerName: String
    let summary: String
    let peerId: String

    /// The UserDefaults key that controls whether this trigger category is enabled.
    var preferenceKey: String {
        switch trigger {
        case .question:        return "incomingCall_question"
        case .permission:      return "incomingCall_permission"
        case .completed:       return "incomingCall_completed"
        case .failed:          return "incomingCall_failed"
        case .planReady:       return "incomingCall_planReview"
        case .writebackReady:  return "incomingCall_writebackReview"
        case .allTasksDone:    return "incomingCall_allFinished"
        }
    }

    var localizedCallerName: String {
        switch trigger {
        case .question:        return "Hivecrew · Question from \(workerName)"
        case .permission:      return "Hivecrew · Permission needed"
        case .completed:       return "Hivecrew · \(workerName) finished"
        case .failed:          return "Hivecrew · \(workerName) failed"
        case .planReady:       return "Hivecrew · Plan ready"
        case .writebackReady:  return "Hivecrew · Review changes"
        case .allTasksDone:    return "Hivecrew · All tasks done"
        }
    }

    /// Parse from a VoIP push payload dictionary.
    static func from(payload: [AnyHashable: Any]) -> IncomingCallContext? {
        guard let triggerRaw = payload["trigger"] as? String,
              let trigger = TriggerEvent(rawValue: triggerRaw),
              let taskId = payload["taskId"] as? String,
              let workerName = payload["workerName"] as? String,
              let summary = payload["summary"] as? String,
              let peerId = payload["peerId"] as? String else {
            return nil
        }
        return IncomingCallContext(
            trigger: trigger,
            taskId: taskId,
            workerName: workerName,
            summary: summary,
            peerId: peerId
        )
    }
}
