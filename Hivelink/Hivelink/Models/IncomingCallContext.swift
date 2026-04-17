//
//  IncomingCallContext.swift
//  Hivelink
//

import Foundation

struct IncomingCallContext: Sendable {
    enum TriggerEvent: String, Sendable, Codable {
        case question, permission, completed, failed
        case planReady, writebackReady
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
        }
    }

    /// Parse from a VoIP push payload dictionary.
    static func from(payload: [AnyHashable: Any]) -> IncomingCallContext? {
        for candidate in candidatePayloads(from: payload) {
            guard let triggerRaw = stringValue(in: candidate, keys: ["trigger", "event", "reason"]),
                  let trigger = TriggerEvent(rawValue: triggerRaw),
                  let taskId = stringValue(in: candidate, keys: ["taskId", "task_id"]) else {
                continue
            }

            let workerName = stringValue(in: candidate, keys: ["workerName", "worker_name"])
                ?? "Worker"
            let summary = stringValue(in: candidate, keys: ["summary", "message", "body"])
                ?? "A task update is ready."
            let peerId = stringValue(in: candidate, keys: ["peerId", "peer_id"]) ?? ""

            return IncomingCallContext(
                trigger: trigger,
                taskId: taskId,
                workerName: workerName,
                summary: summary,
                peerId: peerId
            )
        }
        return nil
    }

    private static func candidatePayloads(from payload: [AnyHashable: Any]) -> [[AnyHashable: Any]] {
        var candidates: [[AnyHashable: Any]] = [payload]

        for key in ["data", "payload", "hivecrew", "context"] {
            if let nested = payload[key] as? [AnyHashable: Any] {
                candidates.append(nested)
            }
            if let nested = payload[key] as? [String: Any] {
                candidates.append(Dictionary(uniqueKeysWithValues: nested.map { ($0.key as AnyHashable, $0.value) }))
            }
            if let json = payload[key] as? String,
               let data = json.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                candidates.append(Dictionary(uniqueKeysWithValues: object.map { ($0.key as AnyHashable, $0.value) }))
            }
        }

        if let aps = payload["aps"] as? [AnyHashable: Any] {
            candidates.append(aps)
        }

        return candidates
    }

    private static func stringValue(in payload: [AnyHashable: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = payload[key] as? String, !value.isEmpty {
                return value
            }
            if let number = payload[key] as? NSNumber {
                return number.stringValue
            }
        }
        return nil
    }
}
