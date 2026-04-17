//
//  NotificationManager.swift
//  Hivelink
//
//  Standard APNs registration, notification categories with actionable buttons,
//  and delegate handling for notification responses.
//

import Combine
import Foundation
import OSLog
import HivecrewShared
import UIKit
import UserNotifications

// MARK: - Deep Link

enum NotificationDeepLink: Equatable {
    case task(id: String)
    case cluster
}

enum VoIPDiagnosticsLog {
    private static let logger = Logger(subsystem: "com.pattonium.Hivelink", category: "VoIP")
    private static let queue = DispatchQueue(label: "com.pattonium.Hivelink.voip-log")
    private static let maxLogBytes: Int64 = 512 * 1024

    static let fileURL = AppPaths.logsDirectory.appendingPathComponent("hivelink-voip.log")

    static func log(_ message: String) {
        print(message)
        logger.info("\(message, privacy: .public)")

        let line = "[\(timestamp())] \(message)\n"
        queue.async {
            append(line)
        }
    }

    static func clear() {
        queue.sync {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private static func append(_ line: String) {
        let data = Data(line.utf8)
        let fm = FileManager.default

        if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
           let size = attrs[.size] as? NSNumber,
           size.int64Value > maxLogBytes {
            try? Data().write(to: fileURL, options: .atomic)
        }

        if !fm.fileExists(atPath: fileURL.path) {
            try? data.write(to: fileURL, options: .atomic)
            return
        }

        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

// MARK: - Notification Manager

@MainActor
final class NotificationManager: NSObject, ObservableObject {

    private static let apnsTokenDefaultsKey = "NotificationManager.apnsTokenHex"

    @Published var pendingDeepLink: NotificationDeepLink?
    @Published private(set) var apnsToken: Data?

    var registeredAPNSTokenString: String? {
        if let apnsToken {
            return apnsToken.map { String(format: "%02x", $0) }.joined()
        }
        return UserDefaults.standard.string(forKey: Self.apnsTokenDefaultsKey)
    }

    /// Set to the task ID currently visible in detail view so that
    /// foreground banners for that task are suppressed.
    var activelyViewedTaskId: String?

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
            VoIPDiagnosticsLog.log("[NotificationManager] Permission request failed: \(error.localizedDescription)")
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
        UserDefaults.standard.set(tokenString, forKey: Self.apnsTokenDefaultsKey)
        VoIPDiagnosticsLog.log("[NotificationManager] APNs token: \(tokenString)")
        sendTokenToServer(tokenString)
    }

    func didFailToRegisterForRemoteNotifications(error: Error) {
        VoIPDiagnosticsLog.log("[NotificationManager] APNs registration failed: \(error.localizedDescription)")
    }

    private func sendTokenToServer(_ token: String) {
        Task {
            await IncomingCallManager.registerPushToken(voipToken: nil, apnsToken: token)
        }
    }

    // MARK: - Preference Keys

    private static let preferenceKeysByCategory: [String: String] = [
        categoryTaskCompleted:  "hivelink.notify_completions",
        categoryTaskFailed:     "hivelink.notify_failures",
        categoryAgentQuestion:  "hivelink.notify_questions",
        categoryToolPermission: "hivelink.notify_permissions",
    ]

    /// Returns whether the user has enabled notifications for a given category.
    /// Categories without a preference key (plan ready, writeback, peer offline)
    /// are always allowed.
    func isNotificationEnabled(forCategory category: String) -> Bool {
        guard let key = Self.preferenceKeysByCategory[category] else { return true }
        if UserDefaults.standard.object(forKey: key) != nil {
            return UserDefaults.standard.bool(forKey: key)
        }
        return true
    }

    // MARK: - Local Notifications

    private static let criticalCategories: Set<String> = [
        categoryAgentQuestion,
        categoryToolPermission,
    ]

    /// Posts a local notification only if the user's preference for the given
    /// category is enabled. Use this for all proactive notifications.
    func postIfEnabled(
        title: String,
        body: String,
        categoryIdentifier: String,
        userInfo: [AnyHashable: Any] = [:]
    ) {
        guard isNotificationEnabled(forCategory: categoryIdentifier) else { return }
        postLocalNotification(
            title: title,
            body: body,
            categoryIdentifier: categoryIdentifier,
            userInfo: userInfo
        )
    }

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

        let taskId = userInfo["taskId"] as? String
        let identifier = taskId.map { "task-\($0)-\(categoryIdentifier ?? "general")" }
            ?? UUID().uuidString

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Notification Cleanup

    /// Removes all delivered notifications associated with a specific task.
    func removeNotifications(forTaskId taskId: String) {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { notifications in
            let matchingIds = notifications
                .filter { $0.request.content.userInfo["taskId"] as? String == taskId }
                .map(\.request.identifier)
            if !matchingIds.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: matchingIds)
            }
        }
    }

    /// Removes all delivered Hivelink task notifications.
    func removeAllTaskNotifications() {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { notifications in
            let taskIds = notifications
                .filter { $0.request.content.userInfo["taskId"] != nil }
                .map(\.request.identifier)
            if !taskIds.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: taskIds)
            }
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationManager: UNUserNotificationCenterDelegate {

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let taskId = notification.request.content.userInfo["taskId"] as? String
        if let taskId {
            let viewedId = await activelyViewedTaskId
            if viewedId == taskId {
                return []
            }
        }
        return [.banner, .sound, .badge]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let taskId = userInfo["taskId"] as? String ?? ""
        let actionId = response.actionIdentifier
        let categoryId = response.notification.request.content.categoryIdentifier
        let replyText = (response as? UNTextInputNotificationResponse)?.userText

        nonisolated(unsafe) let done = completionHandler

        Task { @MainActor [weak self] in
            guard let self else {
                done()
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
                if let replyText, !taskId.isEmpty {
                    self.onQuestionReply?(taskId, replyText)
                }

            case Self.actionApprove:
                if !taskId.isEmpty {
                    if categoryId == Self.categoryToolPermission {
                        self.onPermissionResponse?(taskId, true)
                    } else if categoryId == Self.categoryPlanReady {
                        self.onPlanApproval?(taskId)
                    } else if categoryId == Self.categoryWritebackReady {
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
            done()
        }
    }
}
