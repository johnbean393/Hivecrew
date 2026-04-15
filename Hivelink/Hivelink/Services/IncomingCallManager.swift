//
//  IncomingCallManager.swift
//  Hivelink
//
//  Handles VoIP push (PushKit) registration and incoming CallKit calls.
//  Manages suppression rules, completion batching, and inline delivery
//  for active voice sessions.
//

import Combine
import CallKit
import Foundation
import PushKit
import UIKit

@MainActor
final class IncomingCallManager: NSObject, ObservableObject {

    // MARK: - Dependencies

    private weak var orchestrator: HivelinkVoiceOrchestrator?
    private weak var notificationManager: NotificationManager?
    private let callKitProvider: CXProvider

    // MARK: - State

    /// Contexts waiting for the user to answer or decline.
    private(set) var pendingContexts: [UUID: IncomingCallContext] = [:]

    /// Tracks recent call timestamps per task to prevent spam (60s cooldown).
    private var recentCallTimestamps: [String: Date] = [:]

    /// VoIP push token.
    @Published private(set) var voipToken: Data?

    // MARK: - Completion Batching

    private var completionBatchTimer: Timer?
    private var pendingCompletionContexts: [IncomingCallContext] = []
    private var batchedSilentUUIDs: [UUID] = []

    private static let batchWindowSeconds: TimeInterval = 5
    private static let callCooldownSeconds: TimeInterval = 60

    // MARK: - PushKit

    private var pushRegistry: PKPushRegistry?

    // MARK: - Init

    func configure(
        orchestrator: HivelinkVoiceOrchestrator,
        notificationManager: NotificationManager,
        callKitProvider: CXProvider
    ) {
        self.orchestrator = orchestrator
        self.notificationManager = notificationManager

        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        self.pushRegistry = registry
    }

    // We store callKitProvider at init time so it's available before configure().
    init(callKitProvider: CXProvider) {
        self.callKitProvider = callKitProvider
        super.init()
    }

    // MARK: - Suppression

    /// Defaults matching the @AppStorage declarations in SettingsView.
    private static let preferenceDefaults: [String: Bool] = [
        "hivelink.incomingCallsEnabled": true,
        "incomingCall_question": true,
        "incomingCall_permission": true,
        "incomingCall_completed": false,
        "incomingCall_failed": true,
        "incomingCall_planReview": false,
        "incomingCall_writebackReview": false,
        "incomingCall_allFinished": true,
    ]

    private func preferenceEnabled(forKey key: String) -> Bool {
        if UserDefaults.standard.object(forKey: key) != nil {
            return UserDefaults.standard.bool(forKey: key)
        }
        return Self.preferenceDefaults[key] ?? false
    }

    private func shouldSuppress(context: IncomingCallContext) -> Bool {
        guard preferenceEnabled(forKey: "hivelink.incomingCallsEnabled") else {
            return true
        }

        if !preferenceEnabled(forKey: context.preferenceKey) {
            return true
        }

        if UserDefaults.standard.object(forKey: "focusFilter.allowIncomingCalls") != nil,
           !UserDefaults.standard.bool(forKey: "focusFilter.allowIncomingCalls") {
            return true
        }

        if orchestrator?.isInCall == true {
            return true
        }

        if let lastCall = recentCallTimestamps[context.taskId],
           Date().timeIntervalSince(lastCall) < Self.callCooldownSeconds {
            return true
        }

        return false
    }

    private func recordCallTimestamp(for taskId: String) {
        recentCallTimestamps[taskId] = Date()
        pruneOldTimestamps()
    }

    private func pruneOldTimestamps() {
        let cutoff = Date().addingTimeInterval(-Self.callCooldownSeconds * 2)
        recentCallTimestamps = recentCallTimestamps.filter { $0.value > cutoff }
    }

    // MARK: - Incoming Call Handling

    /// Core handler for a parsed VoIP push. Every VoIP push MUST result in a
    /// `reportNewIncomingCall` to avoid app termination by iOS.
    private func handleIncomingPush(context: IncomingCallContext, completion: @escaping () -> Void) {
        if context.trigger == .question {
            HapticManager.agentQuestionReceived()
        }

        if context.trigger == .completed {
            handleCompletionBatching(context: context, completion: completion)
            return
        }

        let suppressed = shouldSuppress(context: context)
        let uuid = UUID()

        if suppressed {
            reportAndImmediatelyEnd(uuid: uuid, context: context, completion: completion)
        } else {
            reportIncomingCall(uuid: uuid, context: context, completion: completion)
        }
    }

    // MARK: - Completion Batching

    /// If multiple tasks complete within 5 seconds, coalesce into one "All tasks done" call.
    /// Each VoIP push still gets a `reportNewIncomingCall` (iOS requirement).
    private func handleCompletionBatching(context: IncomingCallContext, completion: @escaping () -> Void) {
        pendingCompletionContexts.append(context)

        if pendingCompletionContexts.count == 1 {
            completionBatchTimer = Timer.scheduledTimer(
                withTimeInterval: Self.batchWindowSeconds,
                repeats: false
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.flushCompletionBatch()
                }
            }

            // For the first completion, we wait for the batch window.
            // Report silently to satisfy iOS, will be replaced if batch fires.
            let uuid = UUID()
            batchedSilentUUIDs.append(uuid)
            reportAndImmediatelyEnd(uuid: uuid, context: context, completion: completion)
        } else {
            // Additional completions during the batch window: report + end silently.
            let uuid = UUID()
            batchedSilentUUIDs.append(uuid)
            reportAndImmediatelyEnd(uuid: uuid, context: context, completion: completion)
        }
    }

    private func flushCompletionBatch() {
        completionBatchTimer?.invalidate()
        completionBatchTimer = nil
        batchedSilentUUIDs.removeAll()

        let contexts = pendingCompletionContexts
        pendingCompletionContexts.removeAll()

        guard !contexts.isEmpty else { return }

        if contexts.count > 1 {
            // Coalesce into "All tasks done"
            let coalesced = IncomingCallContext(
                trigger: .allTasksDone,
                taskId: contexts.map(\.taskId).joined(separator: ","),
                workerName: "Hivecrew",
                summary: "\(contexts.count) tasks finished",
                peerId: contexts.first?.peerId ?? ""
            )

            if shouldSuppress(context: coalesced) {
                deliverSuppressedNotification(context: coalesced)
            } else {
                // The VoIP pushes were already reported+ended. Post a local
                // notification or use a CXStartCallAction to ring the user.
                // Since we can't reportNewIncomingCall without a VoIP push,
                // we post a rich local notification instead.
                deliverSuppressedNotification(context: coalesced)
            }
        } else {
            // Single completion -- already handled silently above. Post notification.
            if let single = contexts.first {
                deliverSuppressedNotification(context: single)
            }
        }
    }

    // MARK: - Report Incoming Call (Not Suppressed)

    private func reportIncomingCall(uuid: UUID, context: IncomingCallContext, completion: @escaping () -> Void) {
        recordCallTimestamp(for: context.taskId)
        pendingContexts[uuid] = context

        let update = CXCallUpdate()
        update.localizedCallerName = context.localizedCallerName
        update.hasVideo = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        update.remoteHandle = CXHandle(type: .generic, value: "hivecrew-\(context.trigger.rawValue)")

        callKitProvider.reportNewIncomingCall(with: uuid, update: update) { error in
            if let error {
                print("[IncomingCallManager] Report incoming call failed: \(error.localizedDescription)")
                Task { @MainActor [weak self] in
                    self?.pendingContexts.removeValue(forKey: uuid)
                }
            }
            completion()
        }
    }

    // MARK: - Report + Immediately End (Suppressed)

    private func reportAndImmediatelyEnd(uuid: UUID, context: IncomingCallContext, completion: @escaping () -> Void) {
        nonisolated(unsafe) let done = completion

        let update = CXCallUpdate()
        update.localizedCallerName = context.localizedCallerName
        update.hasVideo = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false

        callKitProvider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            if let error {
                print("[IncomingCallManager] Suppressed report failed: \(error.localizedDescription)")
            }
            Task { @MainActor [weak self] in
                guard let self else {
                    done()
                    return
                }
                self.callKitProvider.reportCall(with: uuid, endedAt: Date(), reason: .unanswered)

                if self.orchestrator?.isInCall == true {
                    self.orchestrator?.deliverInlineUpdate(context: context)
                } else {
                    self.deliverSuppressedNotification(context: context)
                }
                done()
            }
        }
    }

    // MARK: - Suppressed / Declined Notification

    private func deliverSuppressedNotification(context: IncomingCallContext) {
        let category: String
        switch context.trigger {
        case .completed:       category = NotificationManager.categoryTaskCompleted
        case .failed:          category = NotificationManager.categoryTaskFailed
        case .question:        category = NotificationManager.categoryAgentQuestion
        case .permission:      category = NotificationManager.categoryToolPermission
        case .planReady:       category = NotificationManager.categoryPlanReady
        case .writebackReady:  category = NotificationManager.categoryWritebackReady
        case .allTasksDone:    category = NotificationManager.categoryTaskCompleted
        }

        notificationManager?.postLocalNotification(
            title: context.localizedCallerName,
            body: context.summary,
            categoryIdentifier: category,
            userInfo: ["taskId": context.taskId, "peerId": context.peerId]
        )
    }

    // MARK: - Answering / Declining (called from orchestrator's CallKitDelegate)

    /// Called when the user answers the incoming call via CallKit UI.
    func contextForAnsweredCall(uuid: UUID) -> IncomingCallContext? {
        return pendingContexts.removeValue(forKey: uuid)
    }

    /// Called when the user declines the incoming call via CallKit UI.
    func handleDeclinedCall(uuid: UUID) {
        guard let context = pendingContexts.removeValue(forKey: uuid) else { return }
        deliverSuppressedNotification(context: context)
    }

    // MARK: - Token

    private func sendVoIPTokenToServer(_ token: Data) {
        let tokenString = token.map { String(format: "%02x", $0) }.joined()
        print("[IncomingCallManager] VoIP token: \(tokenString)")
        // TODO: Send VoIP push token to the Worker API
    }
}

// MARK: - PKPushRegistryDelegate

extension IncomingCallManager: PKPushRegistryDelegate {

    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didUpdate pushCredentials: PKPushCredentials,
        for type: PKPushType
    ) {
        guard type == .voIP else { return }
        let tokenData = pushCredentials.token
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.voipToken = tokenData
            self.sendVoIPTokenToServer(tokenData)
        }
    }

    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        guard type == .voIP else {
            completion()
            return
        }

        nonisolated(unsafe) let payloadDict = payload.dictionaryPayload
        nonisolated(unsafe) let done = completion

        Task { @MainActor [weak self] in
            guard let self else {
                done()
                return
            }

            guard let context = IncomingCallContext.from(payload: payloadDict) else {
                let uuid = UUID()
                let update = CXCallUpdate()
                update.localizedCallerName = "Hivecrew"
                self.callKitProvider.reportNewIncomingCall(with: uuid, update: update) { _ in
                    Task { @MainActor in
                        self.callKitProvider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
                        done()
                    }
                }
                return
            }

            self.handleIncomingPush(context: context, completion: done)
        }
    }

    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didInvalidatePushTokenFor type: PKPushType
    ) {
        guard type == .voIP else { return }
        Task { @MainActor [weak self] in
            self?.voipToken = nil
        }
    }
}
