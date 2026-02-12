//
//  ContextCompactionPolicy.swift
//  HivecrewLLM
//
//  Shared compaction policy for proactive and reactive decisions.
//

import Foundation

public enum ContextCompactionReason: String, Sendable, Codable {
    case threshold85
    case contextExceeded
}

public struct ContextCompactionDecision: Sendable, Equatable {
    public let shouldCompact: Bool
    public let reason: ContextCompactionReason?
    public let fillRatio: Double?

    public init(shouldCompact: Bool, reason: ContextCompactionReason?, fillRatio: Double?) {
        self.shouldCompact = shouldCompact
        self.reason = reason
        self.fillRatio = fillRatio
    }
}

public enum ContextCompactionPolicy {
    public static let thresholdFillRatio = 0.85

    public static func proactiveDecision(
        estimatedPromptTokens: Int,
        maxInputTokens: Int?
    ) -> ContextCompactionDecision {
        guard let maxInputTokens, maxInputTokens > 0 else {
            return ContextCompactionDecision(
                shouldCompact: false,
                reason: nil,
                fillRatio: nil
            )
        }

        let fillRatio = PromptUsageEstimator.fillRatio(
            estimatedPromptTokens: estimatedPromptTokens,
            maxInputTokens: maxInputTokens
        )
        let shouldCompact = fillRatio >= thresholdFillRatio
        return ContextCompactionDecision(
            shouldCompact: shouldCompact,
            reason: shouldCompact ? .threshold85 : nil,
            fillRatio: fillRatio
        )
    }

    public static func compactionReason(for error: Error) -> ContextCompactionReason? {
        if let llmError = error as? LLMError {
            if llmError.isPayloadTooLarge || llmError.isContextLimitExceeded {
                return .contextExceeded
            }
        }

        if ContextLimitErrorParser.parse(error: error) != nil {
            return .contextExceeded
        }

        return nil
    }

    public static func shouldCompact(for error: Error) -> Bool {
        compactionReason(for: error) != nil
    }
}
