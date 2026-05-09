//
//  VoiceToolCallCoordinator.swift
//  HivecrewVoice
//

import Foundation

public struct VoiceToolExecutionSegment: Sendable {
    public let toolCalls: [VoiceToolCall]
    public let runsInParallel: Bool
}

public enum VoiceToolExecutionPlanner {
    public static let defaultParallelSafeTools: Set<String> = [
        "get_task_status",
        "capture_reference",
        "search_files",
        "get_deliverables",
        "read_file",
        "search_file_content"
    ]

    public static func canRunInParallel(_ toolName: String) -> Bool {
        defaultParallelSafeTools.contains(toolName)
    }

    public static func segments(
        for toolCalls: [VoiceToolCall],
        canRunInParallel: (String) -> Bool = VoiceToolExecutionPlanner.canRunInParallel
    ) -> [VoiceToolExecutionSegment] {
        var segments: [VoiceToolExecutionSegment] = []
        var parallelGroup: [VoiceToolCall] = []

        func flushParallelGroup() {
            guard !parallelGroup.isEmpty else { return }
            segments.append(.init(toolCalls: parallelGroup, runsInParallel: true))
            parallelGroup.removeAll()
        }

        for toolCall in toolCalls {
            if canRunInParallel(toolCall.name) {
                parallelGroup.append(toolCall)
            } else {
                flushParallelGroup()
                segments.append(.init(toolCalls: [toolCall], runsInParallel: false))
            }
        }

        flushParallelGroup()
        return segments
    }
}

@MainActor
public final class VoiceToolCallCoordinator {
    private let batchDelayNanos: UInt64
    private let onBatchReady: @MainActor ([VoiceToolCall]) -> Void

    private var pendingToolCalls: [VoiceToolCall] = []
    private var seenToolCallIDs = Set<String>()
    private var scheduledFlush: Task<Void, Never>?

    public init(
        batchDelayMilliseconds: Int = 120,
        onBatchReady: @escaping @MainActor ([VoiceToolCall]) -> Void
    ) {
        self.batchDelayNanos = UInt64(max(0, batchDelayMilliseconds)) * 1_000_000
        self.onBatchReady = onBatchReady
    }

    public func enqueue(_ toolCall: VoiceToolCall) {
        guard seenToolCallIDs.insert(toolCall.id).inserted else { return }

        pendingToolCalls.append(toolCall)
        scheduleFlush()
    }

    public func flushNow() {
        scheduledFlush?.cancel()
        scheduledFlush = nil

        guard !pendingToolCalls.isEmpty else { return }
        let batch = pendingToolCalls
        pendingToolCalls.removeAll()
        onBatchReady(batch)
    }

    public func reset() {
        scheduledFlush?.cancel()
        scheduledFlush = nil
        pendingToolCalls.removeAll()
        seenToolCallIDs.removeAll()
    }

    private func scheduleFlush() {
        scheduledFlush?.cancel()
        scheduledFlush = Task { @MainActor [weak self, batchDelayNanos] in
            if batchDelayNanos > 0 {
                try? await Task.sleep(nanoseconds: batchDelayNanos)
            }
            guard !Task.isCancelled else { return }
            self?.flushNow()
        }
    }
}
