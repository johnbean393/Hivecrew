//
//  HapticManager.swift
//  Hivelink
//

import UIKit

enum HapticManager {
    static func taskCreated() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func taskCompleted() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func taskFailed() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    static func agentQuestionReceived() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    static func voiceSessionConnected() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func submitPrompt() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    static func incomingCallAnswered() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}
