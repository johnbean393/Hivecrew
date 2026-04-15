//
//  NotificationManager.swift
//  Hivelink
//
//  Standard APNs registration, notification categories with actionable buttons,
//  and delegate handling for notification responses.
//

import Foundation
import UIKit
import UserNotifications

// MARK: - Deep Link

enum NotificationDeepLink: Equatable {
    case task(id: String)
    case cluster
}

// MARK: - Notification Manager

@MainActor
final class NotificationManager: NSObject, ObservableObject {

    @Published var pendingDeepLink: NotificationDeepLink?
    @Published private(set) var apnsToken: Data?

    // MARK: - Category Identifiers

    static let categoryTaskCompleted   = "taskCompleted"
    static let categoryTaskFailed      = "taskFailed"
    static let categoryAgentQuestion   = "agentQuestion"
    static let categoryToolPermission  = "toolPermission"
    static let categoryPlanReady       = "planReady"
    static let categoryWritebackReady  = "writebackReady"
    static let categoryPeerOffline     = "peerOffline"

    // MARK: - Action Identifiers

    static let actionView          = "VIEW"
    static let actionRerun         = "RERUN"
    static let actionTextReply     = "TEXT_REPLY"
    static let actionApprove       = "APPROVE"
    static let actionDeny          = "DENY"
    static let actionDiscard       = "DISCARD"
    static let actionViewCluster   = "VIEW_CLUSTER"

    // MARK: - Callbacks

    /// Called when a text-reply action is received for an agent question.
    var onQuestionReply: ((_ taskId: String, _ reply: String) -> Void)?
    /// Called when a permission response action is received.
    var onPermissionResponse: ((_ taskId: String, _ approved: Bool) -> Void)?
    /// Called when a plan approval action is received.
    var onPlanApproval: ((_ taskId: String) -> Void)?
    /// Called when a writeback approval or discard action is received.
    var onWritebackResponse: ((_ taskId: String, _ approved: Bool) -> Void)?
    /// Called when a rerun action is received.
    var onRerun: ((_ taskId: String) -> Void)?

    // MARK: - Setup

    func requestPermissions() async {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            if granted {
                registerCategories()
                registerForRemoteNotifications()
            }
        } catch {
            print("[NotificationManager] Permission request failed: \(error.localizedDescription)")
        }
    }

    private func registerCategories() {
        let viewAction = UNNotificationAction(
            identifier: Self.actionView,
            title: "View",
            options: [.foreground]
        )
        let rerunAction = UNNotificationAction(
            identifier: Self.actionRerun,
            title: "Rerun",
            options: [.foreground]
        )
        let textReplyAction = UNTextInputNotificationAction(
            identifier: Self.actionTextReply,
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Your answer…"
        )
        let approveAction = UNNotificationAction(
            identifier: Self.actionApprove,
            title: "Approve",
            options: []
        )
        let denyAction = UNNotificationAction(
            identifier: Self.actionDeny,
            title: "Deny",
            options: [.destructive]
        )
        let discardAction = UNNotificationAction(
            identifier: Self.actionDiscard,
            title: "Discard",
            options: [.destructive]
        )
        let viewClusterAction = UNNotificationAction(
            identifier: Self.actionViewCluster,
            title: "View Cluster",
            options: [.foreground]
        )

        let taskCompleted = UNNotificationCategory(
            identifier: Self.categoryTaskCompleted,
            actions: [viewAction, rerunAction],
            intentIdentifiers: []
        )
        let taskFailed = UNNotificationCategory(
            identifier: Self.categoryTaskFailed,
            actions: [viewAction, rerunAction],
            intentIdentifiers: []
        )
        let agentQuestion = UNNotificationCategory(
            identifier: Self.categoryAgentQuestion,
            actions: [viewAction, textReplyAction],
            intentIdentifiers: []
        )
        let toolPermission = UNNotificationCategory(
            identifier: Self.categoryToolPermission,
            actions: [approveAction, denyAction],
            intentIdentifiers: []
        )
        let planReady = UNNotificationCategory(
            identifier: Self.categoryPlanReady,
            actions: [approveAction, viewAction],
            intentIdentifiers: []
        )
        let writebackReady = UNNotificationCategory(
            identifier: Self.categoryWritebackReady,
            actions: [approveAction, discardAction, viewAction],
            intentIdentifiers: []
        )
        let peerOffline = UNNotificationCategory(
            identifier: Self.categoryPeerOffline,
            actions: [viewClusterAction],
            intentIdentifiers: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([
            taskCompleted, taskFailed, agentQuestion, toolPermission,
            planReady, writebackReady, peerOffline,
        ])
    }

    private func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    // MARK: - Token Handling

    func didRegisterForRemoteNotifications(deviceToken: Data) {
        apnsToken = deviceToken
        let tokenString = deviceToken.map { String(format: "%02x", $0) }.joined()
        print("[NotificationManager] APNs token: \(tokenString)")
        sendTokenToServer(tokenString)
    }

    func didFailToRegisterForRemoteNotifications(error: Error) {
        print("[NotificationManager] APNs registration failed: \(error.localizedDescription)")
    }

    private func sendTokenToServer(_ token: String) {
        // TODO: Send APNs device token to the Worker API
    }

    // MARK: - Local Notifications

    private static let criticalCategories: Set<String> = [
        categoryAgentQuestion,
        categoryToolPermission,
    ]

    func postLocalNotification(
        title: String,
        body: String,
        categoryIdentifier: String? = nil,
        userInfo: [AnyHashable: Any] = [:]
    ) {
        if let category = categoryIdentifier,
           UserDefaults.standard.object(forKey: "focusFilter.allowNotifications") != nil,
           !UserDefaults.standard.bool(forKey: "focusFilter.allowNotifications"),
           !Self.criticalCategories.contains(category) {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let category = categoryIdentifier {
            content.categoryIdentifier = category
        }
        content.userInfo = userInfo

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationManager: UNUserNotificationCenterDelegate {

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let taskId = userInfo["taskId"] as? String ?? ""
        let actionId = response.actionIdentifier

        Task { @MainActor [weak self] in
            guard let self else {
                completionHandler()
                return
            }
            switch actionId {
            case Self.actionView, UNNotificationDefaultActionIdentifier:
                if !taskId.isEmpty {
                    self.pendingDeepLink = .task(id: taskId)
                }

            case Self.actionViewCluster:
                self.pendingDeepLink = .cluster

            case Self.actionRerun:
                if !taskId.isEmpty {
                    self.onRerun?(taskId)
                }

            case Self.actionTextReply:
                if let textResponse = response as? UNTextInputNotificationResponse, !taskId.isEmpty {
                    self.onQuestionReply?(taskId, textResponse.userText)
                }

            case Self.actionApprove:
                let category = response.notification.request.content.categoryIdentifier
                if !taskId.isEmpty {
                    if category == Self.categoryToolPermission {
                        self.onPermissionResponse?(taskId, true)
                    } else if category == Self.categoryPlanReady {
                        self.onPlanApproval?(taskId)
                    } else if category == Self.categoryWritebackReady {
                        self.onWritebackResponse?(taskId, true)
                    }
                }

            case Self.actionDeny:
                if !taskId.isEmpty {
                    self.onPermissionResponse?(taskId, false)
                }

            case Self.actionDiscard:
                if !taskId.isEmpty {
                    self.onWritebackResponse?(taskId, false)
                }

            default:
                break
            }
            completionHandler()
        }
    }
}
