//
//  PromptUsageEstimator.swift
//  HivecrewLLM
//
//  Lightweight prompt token estimator for preflight context budgeting.
//

import Foundation

public enum PromptUsageEstimator {
    private static let charsPerToken = 4.0
    private static let messageOverheadTokens = 4
    private static let toolOverheadTokens = 10

    public static func estimatePromptTokens(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?
    ) -> Int {
        var estimated = 0

        for message in messages {
            estimated += messageOverheadTokens

            if let name = message.name, !name.isEmpty {
                estimated += estimateTextTokens(name)
            }

            if let reasoning = message.reasoning, !reasoning.isEmpty {
                estimated += estimateTextTokens(reasoning)
            }

            for part in message.content {
                switch part {
                case .text(let text):
                    estimated += estimateTextTokens(text)
                case .toolResult(_, let content):
                    estimated += estimateTextTokens(content)
                case .imageBase64(let data, _):
                    estimated += estimateImageBase64Tokens(data)
                case .imageURL(let url):
                    estimated += estimateImageURLTokens(url)
                }
            }
        }

        if let tools, !tools.isEmpty {
            for tool in tools {
                estimated += toolOverheadTokens
                estimated += estimateTextTokens(tool.function.name)
                estimated += estimateTextTokens(tool.function.description)
                estimated += estimateJSONTokens(tool.function.parameters)
            }
        }

        // Request-level framing overhead.
        estimated += 12

        return max(estimated, 0)
    }

    public static func fillRatio(
        estimatedPromptTokens: Int,
        maxInputTokens: Int
    ) -> Double {
        guard maxInputTokens > 0 else {
            return 0
        }
        let ratio = Double(max(estimatedPromptTokens, 0)) / Double(maxInputTokens)
        return max(0, ratio)
    }

    private static func estimateTextTokens(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return 0
        }
        return Int(ceil(Double(trimmed.count) / charsPerToken))
    }

    private static func estimateJSONTokens(_ dictionary: [String: Any]) -> Int {
        guard JSONSerialization.isValidJSONObject(dictionary),
              let data = try? JSONSerialization.data(withJSONObject: dictionary),
              let jsonString = String(data: data, encoding: .utf8) else {
            return 0
        }
        return estimateTextTokens(jsonString)
    }

    private static func estimateImageBase64Tokens(_ base64Data: String) -> Int {
        guard !base64Data.isEmpty else {
            return 0
        }

        // Base64 size is much larger than semantic image-token usage. Use a bounded
        // estimate so vision inputs contribute meaningfully without dominating.
        let estimatedBytes = (base64Data.count * 3) / 4
        let dynamicEstimate = Int(ceil(Double(estimatedBytes) / 900.0))
        return min(max(dynamicEstimate, 512), 4096)
    }

    private static func estimateImageURLTokens(_ url: URL) -> Int {
        let absolute = url.absoluteString
        if absolute.isEmpty {
            return 512
        }
        return 768
    }
}
