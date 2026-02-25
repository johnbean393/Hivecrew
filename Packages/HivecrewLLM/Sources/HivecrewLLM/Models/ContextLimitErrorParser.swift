//
//  ContextLimitErrorParser.swift
//  HivecrewLLM
//
//  Detects and parses context-limit errors from provider responses.
//

import Foundation

public struct ContextLimitErrorInfo: Sendable, Equatable {
    public let maxInputTokens: Int?
    public let requestedTokens: Int?
    public let message: String

    public init(maxInputTokens: Int?, requestedTokens: Int?, message: String) {
        self.maxInputTokens = maxInputTokens
        self.requestedTokens = requestedTokens
        self.message = message
    }
}

public enum ContextLimitErrorParser {
    public static func parse(error: Error) -> ContextLimitErrorInfo? {
        if let llmError = error as? LLMError {
            switch llmError {
            case .contextLimitExceeded(let message, let maxInputTokens, let requestedTokens):
                return ContextLimitErrorInfo(
                    maxInputTokens: maxInputTokens,
                    requestedTokens: requestedTokens,
                    message: message
                )
            case .payloadTooLarge(let message):
                if let parsed = parse(message: message) {
                    return parsed
                }
                return ContextLimitErrorInfo(
                    maxInputTokens: nil,
                    requestedTokens: nil,
                    message: message
                )
            default:
                break
            }
        }

        return parse(message: error.localizedDescription)
    }

    public static func parse(message: String) -> ContextLimitErrorInfo? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let normalized = trimmed.lowercased()
        let hasContextSignal = contextExceededSignals.contains { normalized.contains($0) }
        let maxInputTokens = extractFirstInteger(from: trimmed, patterns: maxLimitPatterns)
        let requestedTokens = extractFirstInteger(from: trimmed, patterns: requestedPatterns)

        guard hasContextSignal || maxInputTokens != nil || requestedTokens != nil else {
            return nil
        }

        return ContextLimitErrorInfo(
            maxInputTokens: maxInputTokens,
            requestedTokens: requestedTokens,
            message: trimmed
        )
    }

    private static let contextExceededSignals: [String] = [
        "maximum input exceeded",
        "max input exceeded",
        "input exceeded",
        "maximum context length",
        "max context length",
        "context length exceeded",
        "context_length_exceeded",
        "context window exceeded",
        "token limit exceeded",
        "prompt is too long",
        "input is too long",
        "too many tokens",
        "payload too large",
        "oversized payload",
        "request entity too large",
        "http 413",
        " 413"
    ]

    private static let maxLimitPatterns: [String] = [
        #"maximum context length is\s*([0-9][0-9,]*)"#,
        #"max(?:imum)? context length(?: is| of|:)?\s*([0-9][0-9,]*)"#,
        #"context window(?: size)?(?: is| of|:)?\s*([0-9][0-9,]*)"#,
        #"input token limit(?: is| of|:)?\s*([0-9][0-9,]*)"#,
        #"token limit(?: is| of|:)?\s*([0-9][0-9,]*)"#
    ]

    private static let requestedPatterns: [String] = [
        #"you requested(?: about)?\s*([0-9][0-9,]*)"#,
        #"requested(?: about)?\s*([0-9][0-9,]*)"#,
        #"request(?:ed)?[^0-9]{0,24}([0-9][0-9,]*)\s*tokens"#,
        #"input(?: tokens)?[^0-9]{0,24}([0-9][0-9,]*)"#
    ]

    private static func extractFirstInteger(from text: String, patterns: [String]) -> Int? {
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) else {
                continue
            }

            let nsText = text as NSString
            let range = NSRange(location: 0, length: nsText.length)
            if let match = regex.firstMatch(in: text, options: [], range: range),
               match.numberOfRanges > 1 {
                let rawNumber = nsText.substring(with: match.range(at: 1))
                let normalized = rawNumber.replacingOccurrences(of: ",", with: "")
                if let value = Int(normalized) {
                    return value
                }
            }
        }
        return nil
    }
}
