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

    private var monitors: [String: TaskMonitor] = [:]

    private let sseSession: URLSession

    init(remoteTaskIndex: RemoteTaskIndex, clusterCoordinator: HivelinkClusterCoordinator) {
        self.remoteTaskIndex = remoteTaskIndex
        self.clusterCoordinator = clusterCoordinator

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 0
        config.timeoutIntervalForResource = 86400 * 7
        self.sseSession = URLSession(configuration: config)
    }

    // MARK: - Public API

    /// Begins SSE (or activity fallback) + screenshot polling for a canonical task.
    func startMonitoring(taskId: String, workerTaskId: String, peerUrl: String, clusterToken: String) {
        if monitors[taskId] != nil { return }

        let client = PeerAPIClient(baseURL: peerUrl, clusterToken: clusterToken)
        let streamSession = sseSession

        let eventsTask = Task.detached(priority: .utility) { [weak self] in
            await Self.runEventsLoop(
                manager: self,
                canonicalTaskId: taskId,
                workerTaskId: workerTaskId,
                peerUrl: peerUrl,
                clusterToken: clusterToken,
                client: client,
                sseSession: streamSession
            )
        }

        let shotTask = Task.detached(priority: .utility) { [weak self] in
            await Self.runScreenshotLoop(
                manager: self,
                canonicalTaskId: taskId,
                workerTaskId: workerTaskId,
                client: client
            )
        }

        let questionTask = Task.detached(priority: .utility) { [weak self] in
            await Self.runQuestionPollingLoop(
                manager: self,
                canonicalTaskId: taskId,
                workerTaskId: workerTaskId,
                client: client
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
    }

    fileprivate func setScreenshot(_ image: UIImage?, for canonicalTaskId: String) {
        if let image {
            taskScreenshots[canonicalTaskId] = image
        }
    }

    fileprivate func setPendingQuestion(_ question: APIAgentQuestion?, for canonicalTaskId: String) {
        taskPendingQuestions[canonicalTaskId] = question
    }

    // MARK: - Detached loops (network off main thread)

    private nonisolated static func runEventsLoop(
        manager: PeerConnectionManager?,
        canonicalTaskId: String,
        workerTaskId: String,
        peerUrl: String,
        clusterToken: String,
        client: PeerAPIClient,
        sseSession: URLSession?
    ) async {
        guard let manager, let sseSession else { return }

        var consecutiveSSEFailures = 0
        var activityCursor = 0

        while !Task.isCancelled {
            // Literal thresholds: detached context cannot use MainActor-isolated type members (Swift 6 default isolation).
            if consecutiveSSEFailures >= 3 {
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
                continue
            }

            do {
                try await runSingleSSEConnection(
                    manager: manager,
                    canonicalTaskId: canonicalTaskId,
                    workerTaskId: workerTaskId,
                    peerUrl: peerUrl,
                    clusterToken: clusterToken,
                    sseSession: sseSession
                )
                consecutiveSSEFailures += 1
            } catch {
                consecutiveSSEFailures += 1
            }

            guard !Task.isCancelled else { break }

            let backoff = min(UInt64(1) << UInt64(min(consecutiveSSEFailures, 5)), UInt64(30))
            try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
        }
    }

    private nonisolated static func runSingleSSEConnection(
        manager: PeerConnectionManager,
        canonicalTaskId: String,
        workerTaskId: String,
        peerUrl: String,
        clusterToken: String,
        sseSession: URLSession
    ) async throws {
        let trimmed = peerUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(trimmed)/api/v1/tasks/\(workerTaskId)/events") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(clusterToken)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        let (bytes, response) = try await sseSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        var pendingDataLines: [String] = []
        let eventDecoder = JSONDecoder()
        eventDecoder.dateDecodingStrategy = .iso8601

        for try await line in bytes.lines {
            if Task.isCancelled { break }

            if line.isEmpty {
                if !pendingDataLines.isEmpty {
                    let payload = joinSSEDataLines(pendingDataLines)
                    pendingDataLines.removeAll(keepingCapacity: true)
                    if let data = payload.data(using: .utf8),
                       let event = try? eventDecoder.decode(APITaskEvent.self, from: data) {
                        await MainActor.run {
                            manager.appendEvents([event], for: canonicalTaskId)
                        }
                    }
                }
                continue
            }

            let trimmedLine = String(line).trimmingCharacters(in: .whitespaces)
            if trimmedLine.hasPrefix("data:") {
                let rest = trimmedLine.dropFirst(5).drop(while: { $0 == " " || $0 == "\t" })
                pendingDataLines.append(String(rest))
            }
        }
    }

    private nonisolated static func joinSSEDataLines(_ lines: [String]) -> String {
        lines.joined(separator: "\n")
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
