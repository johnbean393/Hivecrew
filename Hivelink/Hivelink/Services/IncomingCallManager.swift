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
import HivecrewCore
import PushKit
import UIKit

@MainActor
final class IncomingCallManager: NSObject, ObservableObject {

    private static let voipTokenDefaultsKey = "IncomingCallManager.voipTokenHex"

    // MARK: - Dependencies

    private weak var orchestrator: HivelinkVoiceOrchestrator?
    private weak var notificationManager: NotificationManager?
    private let appStoreRegionPolicy: AppStoreRegionPolicy

    // MARK: - State

    /// Contexts waiting for the user to answer or decline.
    private(set) var pendingContexts: [UUID: IncomingCallContext] = [:]

    /// Tracks recent call timestamps per task to prevent spam (60s cooldown).
    private var recentCallTimestamps: [String: Date] = [:]

    /// Task+trigger combinations already reported to CallKit, persisted across launches.
    private var handledTaskTriggers: Set<String> = []

    /// VoIP push token.
    @Published private(set) var voipToken: Data?

    // MARK: - Completion Batching

    private var completionBatchTimer: Timer?
    private var pendingCompletionContexts: [IncomingCallContext] = []

    private static let batchWindowSeconds: TimeInterval = 5
    private static let callCooldownSeconds: TimeInterval = 60
    private static let handledTriggersKey = "IncomingCallManager.handledTaskTriggers"

    // MARK: - PushKit

    private var pushRegistry: PKPushRegistry?

    // MARK: - Init

    func configure(
        orchestrator: HivelinkVoiceOrchestrator,
        notificationManager: NotificationManager
    ) {
        self.orchestrator = orchestrator
        self.notificationManager = notificationManager

        refreshCallKitAvailability()
    }

    func refreshCallKitAvailability() {
        guard appStoreRegionPolicy.isCallKitAllowed else {
            disablePushKitAndStoredVoIPToken()
            return
        }

        guard pushRegistry == nil else { return }
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        self.pushRegistry = registry
        VoIPDiagnosticsLog.log("[IncomingCallManager] PushKit configured")
    }

    init(appStoreRegionPolicy: AppStoreRegionPolicy = .shared) {
        self.appStoreRegionPolicy = appStoreRegionPolicy
        super.init()
        if let stored = UserDefaults.standard.array(forKey: Self.handledTriggersKey) as? [String] {
            handledTaskTriggers = Set(stored)
        }
    }

    private func disablePushKitAndStoredVoIPToken() {
        pushRegistry?.delegate = nil
        pushRegistry?.desiredPushTypes = []
        pushRegistry = nil
        voipToken = nil
        UserDefaults.standard.removeObject(forKey: Self.voipTokenDefaultsKey)
        VoIPDiagnosticsLog.log("[IncomingCallManager] PushKit disabled for App Store storefront")
    }

    // MARK: - Suppression

    /// Defaults matching the @AppStorage declarations in SettingsView.
    static let preferenceDefaults: [String: Bool] = [
        "hivelink.incomingCallsEnabled": true,
        "incomingCall_question": true,
        "incomingCall_permission": true,
        "incomingCall_completed": false,
        "incomingCall_failed": true,
        "incomingCall_planReview": true,
        "incomingCall_writebackReview": false,
    ]

    private enum SuppressionReason {
        case incomingCallsDisabled
        case triggerDisabled
        case focusFilter
        case alreadyInCall
        case cooldown
    }

    static func registerPreferenceDefaults() {
        UserDefaults.standard.register(defaults: preferenceDefaults)
        VoIPDiagnosticsLog.log("[IncomingCallManager] Registered incoming call preference defaults")
    }

    private func preferenceEnabled(forKey key: String) -> Bool {
        if UserDefaults.standard.object(forKey: key) != nil {
            return UserDefaults.standard.bool(forKey: key)
        }
        return Self.preferenceDefaults[key] ?? false
    }

    private func suppressionReason(for context: IncomingCallContext) -> SuppressionReason? {
        guard preferenceEnabled(forKey: "hivelink.incomingCallsEnabled") else {
            return .incomingCallsDisabled
        }

        if !preferenceEnabled(forKey: context.preferenceKey) {
            return .triggerDisabled
        }

        if !FocusFilterPreferences.allowIncomingCalls {
            return .focusFilter
        }

        if orchestrator?.isInCall == true {
            return .alreadyInCall
        }

        if let lastCall = recentCallTimestamps[context.taskId],
           Date().timeIntervalSince(lastCall) < Self.callCooldownSeconds {
            return .cooldown
        }

        return nil
    }

    private func describe(_ reason: SuppressionReason) -> String {
        switch reason {
        case .incomingCallsDisabled: return "incoming_calls_disabled"
        case .triggerDisabled: return "trigger_disabled"
        case .focusFilter: return "focus_filter"
        case .alreadyInCall: return "already_in_call"
        case .cooldown: return "cooldown"
        }
    }

    private func recordCallTimestamp(for taskId: String) {
        recentCallTimestamps[taskId] = Date()
        pruneOldTimestamps()
    }

    private func pruneOldTimestamps() {
        let cutoff = Date().addingTimeInterval(-Self.callCooldownSeconds * 2)
        recentCallTimestamps = recentCallTimestamps.filter { $0.value > cutoff }
    }

    // MARK: - Cross-Path Deduplication

    private func recordHandledTrigger(context: IncomingCallContext) {
        let key = "\(context.taskId):\(context.trigger.rawValue)"
        guard handledTaskTriggers.insert(key).inserted else { return }
        persistHandledTriggers()
    }

    func clearHandledCall(taskId: String, trigger: IncomingCallContext.TriggerEvent) {
        let key = "\(taskId):\(trigger.rawValue)"
        guard handledTaskTriggers.remove(key) != nil else { return }
        persistHandledTriggers()
    }

    private func persistHandledTriggers() {
        var array = Array(handledTaskTriggers)
        if array.count > 500 {
            array = Array(array.suffix(250))
            handledTaskTriggers = Set(array)
        }
        UserDefaults.standard.set(array, forKey: Self.handledTriggersKey)
    }

    /// Whether a call for this task+trigger was already reported via any path (VoIP or local).
    func hasHandledCall(taskId: String, trigger: IncomingCallContext.TriggerEvent) -> Bool {
        handledTaskTriggers.contains("\(taskId):\(trigger.rawValue)")
    }

    // MARK: - Local Call Triggering

    /// Offers an incoming call triggered locally (not from a VoIP push).
    /// Use this when the app is in the foreground and detects a state change
    /// that warrants an incoming call (e.g. plan ready, task completed).
    func offerCall(context: IncomingCallContext) {
        if context.trigger == .question {
            HapticManager.agentQuestionReceived()
        }

        guard appStoreRegionPolicy.isCallKitAllowed else {
            recordHandledTrigger(context: context)
            VoIPDiagnosticsLog.log("[IncomingCallManager] Routing local callback to notification mode: trigger=\(context.trigger.rawValue) task=\(context.taskId)")
            if orchestrator?.isInCall == true {
                orchestrator?.deliverInlineUpdate(context: context)
            } else {
                deliverSuppressedNotification(context: context)
            }
            return
        }

        if let reason = suppressionReason(for: context) {
            recordHandledTrigger(context: context)
            VoIPDiagnosticsLog.log("[IncomingCallManager] Local call suppressed: trigger=\(context.trigger.rawValue) task=\(context.taskId) reason=\(describe(reason))")
            handleSuppressedLocalDelivery(context: context, reason: reason)
            return
        }

        VoIPDiagnosticsLog.log("[IncomingCallManager] Offering local call: trigger=\(context.trigger.rawValue) task=\(context.taskId)")
        let uuid = UUID()
        reportIncomingCall(uuid: uuid, context: context, completion: {})
    }

    // MARK: - Incoming Call Handling

    /// Core handler for a parsed VoIP push. Every VoIP push MUST result in a
    /// `reportNewIncomingCall` to avoid app termination by iOS.
    private func handleIncomingPush(context: IncomingCallContext, completion: @escaping () -> Void) {
        if context.trigger == .question {
            HapticManager.agentQuestionReceived()
        }

        guard appStoreRegionPolicy.isCallKitAllowed else {
            recordHandledTrigger(context: context)
            VoIPDiagnosticsLog.log("[IncomingCallManager] VoIP push received while CallKit disabled; delivering notification fallback")
            deliverSuppressedNotification(context: context)
            completion()
            return
        }

        let suppressed = suppressionReason(for: context) != nil
        VoIPDiagnosticsLog.log("[IncomingCallManager] Received VoIP push: trigger=\(context.trigger.rawValue) task=\(context.taskId) suppressed=\(suppressed)")

        // Completion events may be batched into notifications when call delivery is disabled
        // or otherwise suppressed, but they should behave like real incoming calls when calls
        // are allowed for this trigger.
        if context.trigger == .completed && suppressed {
            handleCompletionBatching(context: context, completion: completion)
            return
        }
        let uuid = UUID()

        if suppressed {
            reportAndImmediatelyEnd(uuid: uuid, context: context, completion: completion)
        } else {
            reportIncomingCall(uuid: uuid, context: context, completion: completion)
        }
    }

    // MARK: - Completion Batching

    /// Delay completion notifications briefly so near-simultaneous task finishes
    /// are delivered together after the silent CallKit reports complete.
    private func handleCompletionBatching(context: IncomingCallContext, completion: @escaping () -> Void) {
        VoIPDiagnosticsLog.log("[IncomingCallManager] Batching completion push for task=\(context.taskId)")
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
            // Report silently to satisfy iOS, then flush notifications later.
            let uuid = UUID()
            reportAndImmediatelyEnd(uuid: uuid, context: context, completion: completion)
        } else {
            // Additional completions during the batch window: report + end silently.
            let uuid = UUID()
            reportAndImmediatelyEnd(uuid: uuid, context: context, completion: completion)
        }
    }

    private func flushCompletionBatch() {
        completionBatchTimer?.invalidate()
        completionBatchTimer = nil

        let contexts = pendingCompletionContexts
        pendingCompletionContexts.removeAll()

        guard !contexts.isEmpty else { return }

        for context in contexts {
            VoIPDiagnosticsLog.log("[IncomingCallManager] Flushing batched completion notification for task=\(context.taskId)")
            deliverSuppressedNotification(context: context)
        }
    }

    private func handleSuppressedLocalDelivery(
        context: IncomingCallContext,
        reason: SuppressionReason
    ) {
        if reason == .alreadyInCall {
            VoIPDiagnosticsLog.log("[IncomingCallManager] Delivering inline update for task=\(context.taskId) trigger=\(context.trigger.rawValue)")
            orchestrator?.deliverInlineUpdate(context: context)
            return
        }
        VoIPDiagnosticsLog.log("[IncomingCallManager] Delivering suppressed local notification for task=\(context.taskId) trigger=\(context.trigger.rawValue)")
        deliverSuppressedNotification(context: context)
    }

    // MARK: - Report Incoming Call (Not Suppressed)

    private func reportIncomingCall(uuid: UUID, context: IncomingCallContext, completion: @escaping () -> Void) {
        guard appStoreRegionPolicy.isCallKitAllowed, let callKitProvider = orchestrator?.callKitProvider else {
            recordHandledTrigger(context: context)
            deliverSuppressedNotification(context: context)
            completion()
            return
        }

        recordCallTimestamp(for: context.taskId)
        recordHandledTrigger(context: context)
        pendingContexts[uuid] = context
        VoIPDiagnosticsLog.log("[IncomingCallManager] Reporting incoming CallKit call: trigger=\(context.trigger.rawValue) task=\(context.taskId) uuid=\(uuid.uuidString)")

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
                VoIPDiagnosticsLog.log("[IncomingCallManager] Report incoming call failed: \(error.localizedDescription)")
                Task { @MainActor [weak self] in
                    self?.pendingContexts.removeValue(forKey: uuid)
                }
            } else {
                VoIPDiagnosticsLog.log("[IncomingCallManager] Report incoming call succeeded: task=\(context.taskId) uuid=\(uuid.uuidString)")
            }
            completion()
        }
    }

    // MARK: - Report + Immediately End (Suppressed)

    private func reportAndImmediatelyEnd(uuid: UUID, context: IncomingCallContext, completion: @escaping () -> Void) {
        guard appStoreRegionPolicy.isCallKitAllowed, let callKitProvider = orchestrator?.callKitProvider else {
            recordHandledTrigger(context: context)
            deliverSuppressedNotification(context: context)
            completion()
            return
        }

        recordCallTimestamp(for: context.taskId)
        recordHandledTrigger(context: context)
        nonisolated(unsafe) let done = completion
        VoIPDiagnosticsLog.log("[IncomingCallManager] Reporting suppressed call then ending immediately: trigger=\(context.trigger.rawValue) task=\(context.taskId) uuid=\(uuid.uuidString)")

        let update = CXCallUpdate()
        update.localizedCallerName = context.localizedCallerName
        update.hasVideo = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false

        callKitProvider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            if let error {
                VoIPDiagnosticsLog.log("[IncomingCallManager] Suppressed report failed: \(error.localizedDescription)")
            }
            Task { @MainActor [weak self] in
                guard let self else {
                    done()
                    return
                }
                self.orchestrator?.callKitProvider?.reportCall(with: uuid, endedAt: Date(), reason: .unanswered)

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
        VoIPDiagnosticsLog.log("[IncomingCallManager] Posting notification fallback: trigger=\(context.trigger.rawValue) task=\(context.taskId)")
        let category: String
        switch context.trigger {
        case .completed:       category = NotificationManager.categoryTaskCompleted
        case .failed:          category = NotificationManager.categoryTaskFailed
        case .question:        category = NotificationManager.categoryAgentQuestion
        case .permission:      category = NotificationManager.categoryToolPermission
        case .planReady:       category = NotificationManager.categoryPlanReady
        case .writebackReady:  category = NotificationManager.categoryWritebackReady
        }

        notificationManager?.postIfEnabled(
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
        guard appStoreRegionPolicy.isCallKitAllowed else {
            voipToken = nil
            UserDefaults.standard.removeObject(forKey: Self.voipTokenDefaultsKey)
            VoIPDiagnosticsLog.log("[IncomingCallManager] Ignoring VoIP token because CallKit is disabled")
            Task {
                await Self.registerPushToken(voipToken: nil, apnsToken: nil)
            }
            return
        }

        let tokenString = token.map { String(format: "%02x", $0) }.joined()
        VoIPDiagnosticsLog.log("[IncomingCallManager] VoIP token: \(tokenString)")
        Task {
            await Self.registerPushToken(voipToken: tokenString, apnsToken: nil)
        }
    }

    func syncStoredPushTokensToServer(apnsTokenString: String?) async {
        let voipTokenString: String?
        if appStoreRegionPolicy.isCallKitAllowed {
            voipTokenString = voipToken.map { data in
                data.map { String(format: "%02x", $0) }.joined()
            } ?? UserDefaults.standard.string(forKey: Self.voipTokenDefaultsKey)
        } else {
            voipTokenString = nil
            UserDefaults.standard.removeObject(forKey: Self.voipTokenDefaultsKey)
        }

        guard voipTokenString != nil || apnsTokenString != nil else { return }
        VoIPDiagnosticsLog.log("[IncomingCallManager] Syncing stored push tokens to server. voip=\(voipTokenString != nil) apns=\(apnsTokenString != nil)")
        await Self.registerPushToken(voipToken: voipTokenString, apnsToken: apnsTokenString)
    }

    private static func ensureOwnerId() -> String {
        if let existing = RemoteAccessKeychain.retrieveTunnelId(), !existing.isEmpty {
            return existing
        }

        let generated = "hivelink-\(UUID().uuidString)"
        _ = RemoteAccessKeychain.storeTunnelId(generated)
        VoIPDiagnosticsLog.log("[IncomingCallManager] Generated synthetic owner ID: \(generated)")
        return generated
    }

    private static func resolvedAPNsEnvironment() -> String {
        if let configured = Bundle.main.object(forInfoDictionaryKey: "HivelinkAPNsEnvironment") as? String {
            let normalized = configured.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized == "development" || normalized == "production" {
                return normalized
            }
        }

        #if DEBUG
        return "development"
        #else
        return "production"
        #endif
    }

    static func registerPushToken(voipToken: String?, apnsToken: String?) async {
        guard let sessionToken = RemoteAccessKeychain.retrieveSessionToken() else {
            VoIPDiagnosticsLog.log("[IncomingCallManager] Skipping push token registration: missing session token")
            return
        }
        let ownerId = ensureOwnerId()
        let apnsEnvironment = resolvedAPNsEnvironment()
        let regionPolicy = AppStoreRegionPolicy.shared
        let effectiveVoIPToken = regionPolicy.isCallKitAllowed ? voipToken : nil

        let client = RemoteAccessAPIClient()
        do {
            try await client.registerDevice(
                sessionToken: sessionToken,
                ownerId: ownerId,
                voipToken: effectiveVoIPToken,
                apnsToken: apnsToken,
                apnsEnvironment: apnsEnvironment,
                storefrontCountryCode: regionPolicy.installStorefrontCountryCode,
                callKitAllowed: regionPolicy.isCallKitAllowed,
                callbackDeliveryMode: regionPolicy.callbackDeliveryMode
            )
            VoIPDiagnosticsLog.log("[IncomingCallManager] Registered push tokens with server for owner=\(ownerId). voip=\(effectiveVoIPToken != nil) apns=\(apnsToken != nil) env=\(apnsEnvironment) storefront=\(regionPolicy.installStorefrontCountryCode ?? "unknown") mode=\(regionPolicy.callbackDeliveryMode)")
        } catch {
            VoIPDiagnosticsLog.log("[IncomingCallManager] Device registration failed: \(error.localizedDescription)")
        }
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
            let tokenString = tokenData.map { String(format: "%02x", $0) }.joined()
            UserDefaults.standard.set(tokenString, forKey: Self.voipTokenDefaultsKey)
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

            VoIPDiagnosticsLog.log("[IncomingCallManager] PushKit payload keys: \(payloadDict.keys.map { String(describing: $0) }.sorted())")
            guard let context = IncomingCallContext.from(payload: payloadDict) else {
                VoIPDiagnosticsLog.log("[IncomingCallManager] Failed to parse VoIP push payload")
                guard self.appStoreRegionPolicy.isCallKitAllowed, let callKitProvider = self.orchestrator?.callKitProvider else {
                    done()
                    return
                }
                let uuid = UUID()
                let update = CXCallUpdate()
                update.localizedCallerName = "Hivecrew"
                callKitProvider.reportNewIncomingCall(with: uuid, update: update) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.orchestrator?.callKitProvider?.reportCall(with: uuid, endedAt: Date(), reason: .failed)
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
            UserDefaults.standard.removeObject(forKey: Self.voipTokenDefaultsKey)
        }
    }
}
