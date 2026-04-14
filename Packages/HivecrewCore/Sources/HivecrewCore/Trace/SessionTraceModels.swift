//
//  SessionTraceModels.swift
//  HivecrewCore
//
//  Pure models for session trace (shared with app UI).
//

import SwiftUI

// MARK: - Event Visibility Tracking

public struct TraceTokenUsage: Equatable, Sendable {
    public let prompt: Int
    public let completion: Int
    public let total: Int
    public let reasoningTokens: Int
    public let cacheReadTokens: Int
    public let cacheCreationTokens: Int
    public let model: String?
    public let reasoningEffort: String?

    public static let zero = TraceTokenUsage(prompt: 0, completion: 0, total: 0)

    public init(
        prompt: Int,
        completion: Int,
        total: Int,
        reasoningTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        model: String? = nil,
        reasoningEffort: String? = nil
    ) {
        self.prompt = prompt
        self.completion = completion
        self.total = total
        self.reasoningTokens = reasoningTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.model = model
        self.reasoningEffort = reasoningEffort
    }

    public var effectiveTotal: Int {
        total > 0 ? total : prompt + completion
    }

    public var hasUsage: Bool {
        prompt > 0 || completion > 0 || total > 0
    }

    /// Response tokens = completion - reasoning
    public var responseTokens: Int {
        max(0, completion - reasoningTokens)
    }

    public func adding(_ other: TraceTokenUsage) -> TraceTokenUsage {
        TraceTokenUsage(
            prompt: prompt + other.prompt,
            completion: completion + other.completion,
            total: total + other.total,
            reasoningTokens: reasoningTokens + other.reasoningTokens,
            cacheReadTokens: cacheReadTokens + other.cacheReadTokens,
            cacheCreationTokens: cacheCreationTokens + other.cacheCreationTokens,
            model: model ?? other.model,
            reasoningEffort: reasoningEffort ?? other.reasoningEffort
        )
    }
}

public struct EventVisibility: Equatable, Sendable {
    public let id: String
    public let index: Int
    public let minY: CGFloat
    public let maxY: CGFloat

    public init(id: String, index: Int, minY: CGFloat, maxY: CGFloat) {
        self.id = id
        self.index = index
        self.minY = minY
        self.maxY = maxY
    }
}

public struct VisibleEventPreferenceKey: PreferenceKey {
    public static let defaultValue: [EventVisibility] = []

    public static func reduce(value: inout [EventVisibility], nextValue: () -> [EventVisibility]) {
        value.append(contentsOf: nextValue())
    }
}

// MARK: - Trace Event Info

public struct TraceEventInfo: Identifiable {
    public let id: String
    public let type: String
    public let timestamp: String
    public let step: Int
    public let summary: String
    public let rawJSON: String
    public let screenshotPath: String?
    public let details: String?
    /// Full response text from LLM (when responding with text, not tool calls)
    public let responseText: String?
    /// Reasoning/thinking content from models that support reasoning tokens (optional for backward compatibility)
    public let reasoning: String?
    public let tokenUsage: TraceTokenUsage
    /// Subagent trace path (relative to session directory), if this is a subagent lifecycle event
    public let subagentTracePath: String?
    public let subagentId: String?
    public let subagentStatus: String?
    public let subagentPurpose: String?
    public let subagentDomain: String?

    public init(
        id: String,
        type: String,
        timestamp: String,
        step: Int,
        summary: String,
        rawJSON: String,
        screenshotPath: String? = nil,
        details: String? = nil,
        responseText: String? = nil,
        reasoning: String? = nil,
        tokenUsage: TraceTokenUsage = .zero,
        subagentTracePath: String? = nil,
        subagentId: String? = nil,
        subagentStatus: String? = nil,
        subagentPurpose: String? = nil,
        subagentDomain: String? = nil
    ) {
        self.id = id
        self.type = type
        self.timestamp = timestamp
        self.step = step
        self.summary = summary
        self.rawJSON = rawJSON
        self.screenshotPath = screenshotPath
        self.details = details
        self.responseText = responseText
        self.reasoning = reasoning
        self.tokenUsage = tokenUsage
        self.subagentTracePath = subagentTracePath
        self.subagentId = subagentId
        self.subagentStatus = subagentStatus
        self.subagentPurpose = subagentPurpose
        self.subagentDomain = subagentDomain
    }
}
