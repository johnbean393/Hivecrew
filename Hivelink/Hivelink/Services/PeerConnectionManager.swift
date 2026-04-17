//
//  PeerConnectionManager.swift
//  Hivelink
//
//  Real-time SSE events + screenshot polling for tasks executing on cluster peers.
//

import Combine
import Foundation
import HivecrewAPIModels
import HivecrewCore
import UIKit

// MARK: - PeerConnectionManager

/// Manages per-task monitoring: Server-Sent Events (with activity polling fallback) and screenshot polling.
@MainActor
final class PeerConnectionManager: ObservableObject {

    @Published private(set) var taskEvents: [String: [APITaskEvent]] = [:]
    @Published private(set) var taskScreenshots: [String: UIImage] = [:]
    @Published private(set) var taskPendingQuestions: [String: APIAgentQuestion] = [:]

    private let remoteTaskIndex: RemoteTaskIndex
    private let clusterCoordinator: HivelinkClusterCoordinator

    /// Posts local notifications for agent questions (owned by `HivelinkAppCore`).
    weak var notificationManager: NotificationManager?

    /// Triggers incoming CallKit calls for agent questions (owned by `HivelinkAppCore`).
    weak var incomingCallManager: IncomingCallManager?

    private var monitors: [String: TaskMonitor] = [:]

    /// Question IDs that already triggered a notification, to avoid repeating.
    private var notifiedQuestionIds: Set<String> = []
    /// Permission IDs that already triggered an incoming call locally, to avoid repeating.
    private var notifiedPermissionIds: Set<String> = []
    /// Most recent permission ID per task so repeat permission prompts on the same task can ring again.
    private var currentPermissionIds: [String: String] = [:]

    init(remoteTaskIndex: RemoteTaskIndex, clusterCoordinator: HivelinkClusterCoordinator) {
        self.remoteTaskIndex = remoteTaskIndex
        self.clusterCoordinator = clusterCoordinator
    }

    // MARK: - Public API

    /// Begins SSE (or activity fallback) + screenshot polling for a canonical task.
    func startMonitoring(taskId: String, workerTaskId: String, peerUrl: String, clusterToken: String) {
        if monitors[taskId] != nil { return }

        // Each loop gets its own PeerAPIClient to avoid actor serialization
        // contention (e.g. a slow screenshot download blocking event polls).
        let eventsClient = PeerAPIClient(baseURL: peerUrl, clusterToken: clusterToken)
        let screenshotClient = PeerAPIClient(baseURL: peerUrl, clusterToken: clusterToken)
        let questionClient = PeerAPIClient(baseURL: peerUrl, clusterToken: clusterToken)

        let eventsTask = Task.detached(priority: .utility) { [weak self] in
            await Self.runEventsLoop(
                manager: self,
                canonicalTaskId: taskId,
                workerTaskId: workerTaskId,
                client: eventsClient
            )
        }

        let shotTask = Task.detached(priority: .utility) { [weak self] in
            await Self.runScreenshotLoop(
                manager: self,
                canonicalTaskId: taskId,
                workerTaskId: workerTaskId,
                client: screenshotClient
            )
        }

        let questionTask = Task.detached(priority: .utility) { [weak self] in
            await Self.runQuestionPollingLoop(
                manager: self,
                canonicalTaskId: taskId,
                workerTaskId: workerTaskId,
                client: questionClient
            )
        }

        monitors[taskId] = TaskMonitor(
            workerTaskId: workerTaskId,
            peerUrl: peerUrl,
            eventsTask: eventsTask,
            screenshotTask: shotTask,
            questionTask: questionTask
        )
    }

    func stopMonitoring(taskId: String) {
        guard let monitor = monitors.removeValue(forKey: taskId) else { return }
        monitor.eventsTask.cancel()
        monitor.screenshotTask.cancel()
        monitor.questionTask.cancel()
        taskEvents[taskId] = nil
        taskScreenshots[taskId] = nil
        taskPendingQuestions[taskId] = nil
        currentPermissionIds.removeValue(forKey: taskId)
        incomingCallManager?.clearHandledCall(taskId: taskId, trigger: .permission)
    }

    func stopAll() {
        for id in monitors.keys {
            stopMonitoring(taskId: id)
        }
    }

    func events(for taskId: String) -> [APITaskEvent] {
        taskEvents[taskId] ?? []
    }

    func screenshot(for taskId: String) -> UIImage? {
        taskScreenshots[taskId]
    }

    func pendingQuestion(for taskId: String) -> APIAgentQuestion? {
        taskPendingQuestions[taskId]
    }

    /// Ensures monitoring is running for a single task without affecting other monitors.
    func ensureMonitoring(for task: TaskRecord) async {
        guard monitors[task.id] == nil else { return }
        guard [TaskStatus.running, .waitingForVM, .planning, .paused].contains(task.status) else { return }
        guard let clusterToken = await clusterCoordinator.clusterToken(),
              let workerId = await remoteTaskIndex.workerTaskId(for: task.id),
              let peerId = await remoteTaskIndex.peerId(for: task.id),
              let peer = await clusterCoordinator.peer(id: peerId)
        else { return }

        startMonitoring(
            taskId: task.id,
            workerTaskId: workerId,
            peerUrl: peer.tunnelUrl,
            clusterToken: clusterToken
        )
    }

    /// Starts monitoring for `.running` / `.waitingForVM` tasks with a remote index entry; stops for others.
    func syncMonitoring(tasks: [TaskRecord]) async {
        guard let clusterToken = await clusterCoordinator.clusterToken() else { return }

        let shouldMonitor: (TaskStatus) -> Bool = { [.running, .waitingForVM, .planning, .paused].contains($0) }

        for task in tasks where shouldMonitor(task.status) {
            guard let workerId = await remoteTaskIndex.workerTaskId(for: task.id),
                  let peerId = await remoteTaskIndex.peerId(for: task.id),
                  let peer = await clusterCoordinator.peer(id: peerId)
            else { continue }

            if monitors[task.id] == nil {
                startMonitoring(
                    taskId: task.id,
                    workerTaskId: workerId,
                    peerUrl: peer.tunnelUrl,
                    clusterToken: clusterToken
                )
            }
        }

        let activeIds = Set(tasks.filter { shouldMonitor($0.status) }.map(\.id))
        for canonicalId in monitors.keys {
            if !activeIds.contains(canonicalId) {
                stopMonitoring(taskId: canonicalId)
            }
        }
    }

    // MARK: - MainActor mutations

    fileprivate func appendEvents(_ events: [APITaskEvent], for canonicalTaskId: String) {
        guard !events.isEmpty else { return }
        var list = taskEvents[canonicalTaskId] ?? []
        list.append(contentsOf: events)
        taskEvents[canonicalTaskId] = list
        handlePermissionEvents(events, for: canonicalTaskId)
    }

    fileprivate func setScreenshot(_ image: UIImage?, for canonicalTaskId: String) {
        if let image {
            taskScreenshots[canonicalTaskId] = image
        }
    }

    fileprivate func setPendingQuestion(_ question: APIAgentQuestion?, for canonicalTaskId: String) {
        taskPendingQuestions[canonicalTaskId] = question

        if let question, notifiedQuestionIds.insert(question.id).inserted {
            if incomingCallManager?.hasHandledCall(taskId: canonicalTaskId, trigger: .question) == true {
                return
            }
            let monitor = monitors[canonicalTaskId]
            let context = IncomingCallContext(
                trigger: .question,
                taskId: canonicalTaskId,
                workerName: "Worker",
                summary: question.question,
                peerId: monitor?.peerUrl ?? ""
            )
            VoIPDiagnosticsLog.log("[PeerConnectionManager] Local question trigger: task=\(canonicalTaskId) questionId=\(question.id)")
            incomingCallManager?.offerCall(context: context)
        } else if question == nil {
            VoIPDiagnosticsLog.log("[PeerConnectionManager] Question cleared for task=\(canonicalTaskId)")
            incomingCallManager?.clearHandledCall(taskId: canonicalTaskId, trigger: .question)
        }
    }

    private func handlePermissionEvents(_ events: [APITaskEvent], for canonicalTaskId: String) {
        for event in events where event.type == .permissionRequest {
            guard let permissionId = event.data["id"]?.stringValue else { continue }

            if let currentPermissionId = currentPermissionIds[canonicalTaskId],
               currentPermissionId != permissionId {
                incomingCallManager?.clearHandledCall(taskId: canonicalTaskId, trigger: .permission)
            }
            currentPermissionIds[canonicalTaskId] = permissionId

            guard notifiedPermissionIds.insert(permissionId).inserted else { continue }
            if incomingCallManager?.hasHandledCall(taskId: canonicalTaskId, trigger: .permission) == true {
                continue
            }

            let monitor = monitors[canonicalTaskId]
            let context = IncomingCallContext(
                trigger: .permission,
                taskId: canonicalTaskId,
                workerName: "Worker",
                summary: event.data["details"]?.stringValue ?? "A worker needs permission to continue.",
                peerId: monitor?.peerUrl ?? ""
            )
            VoIPDiagnosticsLog.log("[PeerConnectionManager] Local permission trigger: task=\(canonicalTaskId) permissionId=\(permissionId)")
            incomingCallManager?.offerCall(context: context)
        }
    }

    // MARK: - Detached loops (network off main thread)

    private nonisolated static func runEventsLoop(
        manager: PeerConnectionManager?,
        canonicalTaskId: String,
        workerTaskId: String,
        client: PeerAPIClient
    ) async {
        guard let manager else { return }

        var activityCursor = 0

        // Seed with historical events so the trace is populated immediately
        // after a cold start (SSE only streams new events going forward).
        do {
            let response = try await client.getActivity(taskId: workerTaskId, since: 0)
            activityCursor = response.total
            if !response.events.isEmpty {
                await MainActor.run {
                    manager.appendEvents(response.events, for: canonicalTaskId)
                }
            }
        } catch {
            // Non-fatal; subsequent polls will populate events.
        }

        // Use activity polling exclusively. SSE over tunnel connections can
        // open and hang indefinitely, blocking the loop and preventing any
        // updates from reaching the UI.
        while !Task.isCancelled {
            do {
                let response = try await client.getActivity(taskId: workerTaskId, since: activityCursor)
                activityCursor = response.total
                if !response.events.isEmpty {
                    await MainActor.run {
                        manager.appendEvents(response.events, for: canonicalTaskId)
                    }
                }
            } catch {
                // Keep polling; transient errors are expected.
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private nonisolated static func runScreenshotLoop(
        manager: PeerConnectionManager?,
        canonicalTaskId: String,
        workerTaskId: String,
        client: PeerAPIClient
    ) async {
        guard let manager else { return }
        var lastData: Data?

        while !Task.isCancelled {
            do {
                if let tuple = try await client.getScreenshot(taskId: workerTaskId) {
                    let data = tuple.data
                    if lastData != data {
                        lastData = data
                        let image = await Task.detached(priority: .userInitiated) {
                            UIImage(data: data)
                        }.value
                        if let image {
                            await MainActor.run {
                                manager.setScreenshot(image, for: canonicalTaskId)
                            }
                        }
                    }
                }
            } catch {
                // Ignore transient screenshot errors.
            }

            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private nonisolated static func runQuestionPollingLoop(
        manager: PeerConnectionManager?,
        canonicalTaskId: String,
        workerTaskId: String,
        client: PeerAPIClient
    ) async {
        guard let manager else { return }

        while !Task.isCancelled {
            do {
                let question = try await client.getPendingQuestion(taskId: workerTaskId)
                await MainActor.run {
                    manager.setPendingQuestion(question, for: canonicalTaskId)
                }
            } catch {
                // Transient errors are expected; keep polling.
            }

            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    // MARK: - Nested

    private struct TaskMonitor {
        let workerTaskId: String
        let peerUrl: String
        let eventsTask: Task<Void, Never>
        let screenshotTask: Task<Void, Never>
        let questionTask: Task<Void, Never>
    }
}
