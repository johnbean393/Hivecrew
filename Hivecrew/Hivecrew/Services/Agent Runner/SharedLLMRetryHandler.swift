//
//  SharedLLMRetryHandler.swift
//  Hivecrew
//
//  Shared retry and context-compaction logic for agent runners.
//

import Foundation
import HivecrewLLM

@MainActor
enum SharedLLMRetryHandler {
    struct Options {
        let maxLLMRetries: Int
        let maxContextCompactionRetries: Int
        let baseRetryDelay: Double
        let proactiveCompactionPasses: Int
        let normalToolResultLimit: Int
        let aggressiveToolResultLimit: Int

        static let `default` = Options(
            maxLLMRetries: 3,
            maxContextCompactionRetries: 3,
            baseRetryDelay: 2.0,
            proactiveCompactionPasses: 3,
            normalToolResultLimit: 12000,
            aggressiveToolResultLimit: 8000
        )
    }

    struct Hooks {
        let logInfo: (String) -> Void
        let checkInterruption: (() throws -> Void)?
        let onMessagesChanged: (([LLMMessage]) -> Void)?
        let onImageScaleLevelChanged: ((ImageDownscaler.ScaleLevel) -> Void)?

        init(
            logInfo: @escaping (String) -> Void,
            checkInterruption: (() throws -> Void)? = nil,
            onMessagesChanged: (([LLMMessage]) -> Void)? = nil,
            onImageScaleLevelChanged: ((ImageDownscaler.ScaleLevel) -> Void)? = nil
        ) {
            self.logInfo = logInfo
            self.checkInterruption = checkInterruption
            self.onMessagesChanged = onMessagesChanged
            self.onImageScaleLevelChanged = onImageScaleLevelChanged
        }
    }

    struct Outcome {
        let response: LLMResponse
        let messages: [LLMMessage]
        let imageScaleLevel: ImageDownscaler.ScaleLevel
    }

    typealias LLMCall = @Sendable (
        _ messages: [LLMMessage],
        _ tools: [LLMToolDefinition]?,
        _ onReasoningUpdate: ReasoningStreamCallback?,
        _ onContentUpdate: ContentStreamCallback?
    ) async throws -> LLMResponse

    static func callWithRetry(
        llmClient: any LLMClientProtocol,
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        imageScaleLevel: ImageDownscaler.ScaleLevel,
        onReasoningUpdate: ReasoningStreamCallback?,
        onContentUpdate: ContentStreamCallback?,
        llmCall: LLMCall,
        options: Options = .default,
        hooks: Hooks
    ) async throws -> Outcome {
        var lastError: Error?
        var contextCompactionRetries = 0
        var workingMessages = messages
        var workingScaleLevel = imageScaleLevel

        let initialBudget = await ContextBudgetResolver.shared.resolve(using: llmClient)
        var maxInputTokens = initialBudget.maxInputTokens

        if let maxInputTokens {
            await proactivelyCompactMessagesIfNeeded(
                llmClient: llmClient,
                messages: &workingMessages,
                tools: tools,
                maxInputTokens: maxInputTokens,
                options: options,
                hooks: hooks
            )
        }

        for attempt in 1...options.maxLLMRetries {
            do {
                try hooks.checkInterruption?()
                let response = try await llmCall(
                    workingMessages,
                    tools,
                    onReasoningUpdate,
                    onContentUpdate
                )

                let hasText = !(response.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                let hasToolCalls = !(response.toolCalls?.isEmpty ?? true)
                if !hasText && !hasToolCalls {
                    let responseId = response.id
                    let finishReason = response.finishReason?.rawValue ?? "nil"
                    let choiceCount = response.choices.count
                    throw LLMError.unknown(
                        message: "Empty response from model (id: \(responseId), finishReason: \(finishReason), choices: \(choiceCount))"
                    )
                }

                return Outcome(
                    response: response,
                    messages: workingMessages,
                    imageScaleLevel: workingScaleLevel
                )
            } catch {
                lastError = error

                if let learnedBudget = await learnContextBudget(from: error, llmClient: llmClient, hooks: hooks) {
                    maxInputTokens = learnedBudget.maxInputTokens ?? maxInputTokens
                }

                if let compactionReason = ContextCompactionPolicy.compactionReason(for: error),
                   contextCompactionRetries < options.maxContextCompactionRetries {
                    contextCompactionRetries += 1

                    if isPayloadTooLargeError(error) {
                        if let nextLevel = workingScaleLevel.next {
                            hooks.logInfo("Context compaction triggered (\(compactionReason.rawValue)). Downscaling images to \(nextLevel) and retrying...")
                            workingScaleLevel = nextLevel
                            downscaleMessages(&workingMessages, to: nextLevel)
                            hooks.onImageScaleLevelChanged?(nextLevel)
                            hooks.onMessagesChanged?(workingMessages)
                            continue
                        }

                        hooks.logInfo("Context compaction triggered (\(compactionReason.rawValue)). Removing older images and retrying...")
                        aggressiveCompactMessages(&workingMessages)
                        truncateToolResultsForContextLimit(
                            &workingMessages,
                            maxToolResultChars: options.normalToolResultLimit
                        )
                        hooks.onMessagesChanged?(workingMessages)
                        continue
                    }

                    hooks.logInfo("Context compaction triggered (\(compactionReason.rawValue)). Compacting messages and retrying...")
                    let compacted = await compactMessagesForContextLimit(
                        llmClient: llmClient,
                        &workingMessages,
                        keepMostRecentImageOnly: true,
                        maxToolResultChars: options.normalToolResultLimit,
                        hooks: hooks
                    )
                    if !compacted {
                        aggressiveCompactMessages(&workingMessages)
                        truncateToolResultsForContextLimit(
                            &workingMessages,
                            maxToolResultChars: options.aggressiveToolResultLimit
                        )
                    }
                    hooks.onMessagesChanged?(workingMessages)

                    if let maxInputTokens {
                        await proactivelyCompactMessagesIfNeeded(
                            llmClient: llmClient,
                            messages: &workingMessages,
                            tools: tools,
                            maxInputTokens: maxInputTokens,
                            options: options,
                            hooks: hooks
                        )
                    }

                    continue
                }

                if isEmptyResponseError(error), attempt < options.maxLLMRetries {
                    try hooks.checkInterruption?()
                    let delay = options.baseRetryDelay * pow(2.0, Double(attempt - 1))
                    hooks.logInfo("LLM returned empty response (attempt \(attempt)/\(options.maxLLMRetries)). Retrying in \(Int(delay))s...")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }

                if isRetryableError(error), attempt < options.maxLLMRetries {
                    try hooks.checkInterruption?()
                    let delay = options.baseRetryDelay * pow(2.0, Double(attempt - 1))
                    hooks.logInfo("LLM call failed (attempt \(attempt)/\(options.maxLLMRetries)): \(error.localizedDescription). Retrying in \(Int(delay))s...")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }

                throw error
            }
        }

        throw lastError ?? LLMError.unknown(message: "LLM call failed after \(options.maxLLMRetries) attempts")
    }

    private static func proactivelyCompactMessagesIfNeeded(
        llmClient: any LLMClientProtocol,
        messages: inout [LLMMessage],
        tools: [LLMToolDefinition]?,
        maxInputTokens: Int,
        options: Options,
        hooks: Hooks
    ) async {
        guard maxInputTokens > 0 else {
            return
        }

        for pass in 1...options.proactiveCompactionPasses {
            let estimated = PromptUsageEstimator.estimatePromptTokens(messages: messages, tools: tools)
            let decision = ContextCompactionPolicy.proactiveDecision(
                estimatedPromptTokens: estimated,
                maxInputTokens: maxInputTokens
            )
            guard decision.shouldCompact else {
                return
            }

            let fillPercent = Int(((decision.fillRatio ?? 0) * 100).rounded())
            hooks.logInfo("Context compaction triggered (threshold85): \(estimated)/\(maxInputTokens) tokens (\(fillPercent)% full).")

            let changed = await compactMessagesForContextLimit(
                llmClient: llmClient,
                &messages,
                keepMostRecentImageOnly: false,
                maxToolResultChars: options.normalToolResultLimit,
                hooks: hooks
            )
            if !changed {
                hooks.logInfo("Context remained above threshold but no additional compaction was possible.")
                return
            }

            hooks.onMessagesChanged?(messages)

            let afterEstimate = PromptUsageEstimator.estimatePromptTokens(messages: messages, tools: tools)
            let afterFill = Int(
                (PromptUsageEstimator.fillRatio(
                    estimatedPromptTokens: afterEstimate,
                    maxInputTokens: maxInputTokens
                ) * 100).rounded()
            )
            hooks.logInfo("Context compaction pass \(pass) -> \(afterEstimate)/\(maxInputTokens) tokens (\(afterFill)% full).")
        }
    }

    @discardableResult
    private static func compactMessagesForContextLimit(
        llmClient: any LLMClientProtocol,
        _ messages: inout [LLMMessage],
        keepMostRecentImageOnly: Bool,
        maxToolResultChars: Int,
        hooks: Hooks
    ) async -> Bool {
        var changed = false
        let keepRecentCount = keepMostRecentImageOnly ? 6 : 8
        if await summarizeOlderMessagesWithLLM(
            llmClient: llmClient,
            &messages,
            keepRecentCount: keepRecentCount,
            hooks: hooks
        ) {
            changed = true
        }

        let maxImagesToKeep = keepMostRecentImageOnly ? 1 : 2
        var keptImageMessages = 0

        for i in stride(from: messages.count - 1, through: 0, by: -1) {
            let message = messages[i]
            let hasImages = message.role == .user && message.hasImages
            let shouldDropImages = hasImages && (keptImageMessages >= maxImagesToKeep)
            if hasImages && !shouldDropImages {
                keptImageMessages += 1
            }

            var newContent: [LLMMessageContent] = []
            var removedImages = false

            for part in message.content {
                switch part {
                case .imageBase64, .imageURL:
                    if shouldDropImages {
                        removedImages = true
                    } else {
                        newContent.append(part)
                    }
                case .toolResult(let toolCallId, let content):
                    if content.count > maxToolResultChars {
                        let truncated = String(content.prefix(maxToolResultChars))
                        newContent.append(
                            .toolResult(
                                toolCallId: toolCallId,
                                content: truncated + "\n\n[... truncated to reduce context size ...]"
                            )
                        )
                        changed = true
                    } else {
                        newContent.append(part)
                    }
                default:
                    newContent.append(part)
                }
            }

            if removedImages {
                changed = true
                if newContent.isEmpty {
                    newContent = [.text("[Image removed to reduce context usage]")]
                } else {
                    newContent.append(.text("[Image removed to reduce context usage]"))
                }
            }

            if newContent != message.content {
                changed = true
                messages[i] = LLMMessage(
                    role: message.role,
                    content: newContent,
                    name: message.name,
                    toolCalls: message.toolCalls,
                    toolCallId: message.toolCallId,
                    reasoning: message.reasoning
                )
            }
        }

        return changed
    }

    private static func summarizeOlderMessagesWithLLM(
        llmClient: any LLMClientProtocol,
        _ messages: inout [LLMMessage],
        keepRecentCount: Int,
        hooks: Hooks
    ) async -> Bool {
        let startIndex = messages.first?.role == .system ? 1 : 0
        let endIndexExclusive = max(startIndex, messages.count - keepRecentCount)
        guard endIndexExclusive - startIndex >= 3 else {
            return false
        }

        let olderMessages = Array(messages[startIndex..<endIndexExclusive])
        guard let summary = await generateCompactionSummaryUsingLLM(
            llmClient: llmClient,
            for: olderMessages,
            hooks: hooks
        ) else {
            return false
        }

        let summaryMessage = LLMMessage.assistant(
            """
            [Compacted context summary generated by the model]
            \(summary)
            """
        )
        messages.replaceSubrange(startIndex..<endIndexExclusive, with: [summaryMessage])
        return true
    }

    private static func generateCompactionSummaryUsingLLM(
        llmClient: any LLMClientProtocol,
        for messages: [LLMMessage],
        hooks: Hooks
    ) async -> String? {
        let transcript = buildCompactionTranscript(from: messages, maxCharacters: 24_000)
        guard !transcript.isEmpty else {
            return nil
        }

        let compactionMessages: [LLMMessage] = [
            .system(
                """
                You are compacting prior agent context for future turns.
                Produce a dense factual summary that preserves:
                - user goals and constraints
                - decisions already made
                - completed actions and outcomes
                - unresolved tasks, blockers, and errors
                - exact file paths, commands, and thresholds when present
                Do not invent facts. Keep it concise and scannable.
                """
            ),
            .user(
                """
                Compact this prior context. Return only the summary.

                \(transcript)
                """
            )
        ]

        do {
            let response = try await llmClient.chat(messages: compactionMessages, tools: nil)
            guard let text = response.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                return nil
            }
            return String(text.prefix(8000))
        } catch {
            hooks.logInfo("LLM summary compaction failed: \(error.localizedDescription). Falling back to heuristic compaction.")
            return nil
        }
    }

    private static func buildCompactionTranscript(
        from messages: [LLMMessage],
        maxCharacters: Int
    ) -> String {
        guard maxCharacters > 0 else { return "" }
        var parts: [String] = []
        var totalCount = 0

        for message in messages {
            let roleLabel = message.role.rawValue.uppercased()
            var body = message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)

            let imageCount = message.content.reduce(into: 0) { partial, content in
                switch content {
                case .imageBase64, .imageURL:
                    partial += 1
                default:
                    break
                }
            }
            if imageCount > 0 {
                body += "\n[Images omitted: \(imageCount)]"
            }

            if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                let names = toolCalls.map { $0.function.name }.joined(separator: ", ")
                body += "\n[Tool calls: \(names)]"
            }

            let candidate = "[\(roleLabel)] \(body)"
            guard !candidate.isEmpty else { continue }

            if totalCount + candidate.count > maxCharacters {
                let remaining = max(0, maxCharacters - totalCount)
                if remaining > 64 {
                    parts.append(String(candidate.prefix(remaining)))
                }
                parts.append("[TRUNCATED]")
                break
            }

            parts.append(candidate)
            totalCount += candidate.count
        }

        return parts.joined(separator: "\n\n")
    }

    @discardableResult
    private static func truncateToolResultsForContextLimit(
        _ messages: inout [LLMMessage],
        maxToolResultChars: Int
    ) -> Bool {
        var changed = false
        for i in 0..<messages.count {
            let message = messages[i]
            var updatedContent: [LLMMessageContent] = []
            var messageChanged = false

            for part in message.content {
                switch part {
                case .toolResult(let toolCallId, let content):
                    if content.count > maxToolResultChars {
                        let truncated = String(content.prefix(maxToolResultChars))
                        updatedContent.append(
                            .toolResult(
                                toolCallId: toolCallId,
                                content: truncated + "\n\n[... truncated to reduce context size ...]"
                            )
                        )
                        messageChanged = true
                    } else {
                        updatedContent.append(part)
                    }
                default:
                    updatedContent.append(part)
                }
            }

            if messageChanged {
                changed = true
                messages[i] = LLMMessage(
                    role: message.role,
                    content: updatedContent,
                    name: message.name,
                    toolCalls: message.toolCalls,
                    toolCallId: message.toolCallId,
                    reasoning: message.reasoning
                )
            }
        }
        return changed
    }

    private static func learnContextBudget(
        from error: Error,
        llmClient: any LLMClientProtocol,
        hooks: Hooks
    ) async -> ContextBudget? {
        guard let contextInfo = ContextLimitErrorParser.parse(error: error) else {
            return nil
        }
        let learned = await ContextBudgetResolver.shared.learnContextLimit(
            providerBaseURL: llmClient.configuration.baseURL,
            modelId: llmClient.configuration.model,
            maxInputTokens: contextInfo.maxInputTokens,
            requestedTokens: contextInfo.requestedTokens
        )
        if let learnedLimit = learned?.maxInputTokens {
            hooks.logInfo("Learned context budget from provider error: \(learnedLimit) tokens.")
        }
        return learned
    }

    private static func isPayloadTooLargeError(_ error: Error) -> Bool {
        if let llmError = error as? LLMError, llmError.isPayloadTooLarge {
            return true
        }

        let errorString = error.localizedDescription.lowercased()
        return errorString.contains("413") ||
               errorString.contains("oversized payload") ||
               errorString.contains("payload too large") ||
               errorString.contains("request entity too large")
    }

    private static func isEmptyResponseError(_ error: Error) -> Bool {
        if let llmError = error as? LLMError {
            switch llmError {
            case .noChoices:
                return true
            case .unknown(let message):
                let normalized = message.lowercased()
                return normalized.contains("empty response") || normalized.contains("no content")
            default:
                break
            }
        }

        let errorString = error.localizedDescription.lowercased()
        return errorString.contains("empty response") ||
               errorString.contains("no content") ||
               errorString.contains("no response choices")
    }

    private static func aggressiveCompactMessages(_ messages: inout [LLMMessage]) {
        var foundFirst = false

        for i in stride(from: messages.count - 1, through: 0, by: -1) {
            let message = messages[i]

            if message.role == .user && message.hasImages {
                if foundFirst {
                    let textContent = message.textContent
                    messages[i] = .user("[Image removed to reduce payload size]\n\(textContent)")
                } else {
                    foundFirst = true
                }
            }
        }
    }

    private static func downscaleMessages(_ messages: inout [LLMMessage], to scaleLevel: ImageDownscaler.ScaleLevel) {
        for i in 0..<messages.count {
            let message = messages[i]

            guard message.role == .user && message.hasImages else { continue }

            var newContent: [LLMMessageContent] = []
            var wasModified = false

            for content in message.content {
                switch content {
                case .imageBase64(let data, let mimeType):
                    if let downscaled = ImageDownscaler.downscale(
                        base64Data: data,
                        mimeType: mimeType,
                        to: scaleLevel
                    ) {
                        newContent.append(.imageBase64(data: downscaled.data, mimeType: downscaled.mimeType))
                        wasModified = true
                    } else {
                        newContent.append(content)
                    }
                default:
                    newContent.append(content)
                }
            }

            if wasModified {
                messages[i] = LLMMessage(
                    role: message.role,
                    content: newContent,
                    name: message.name,
                    toolCalls: message.toolCalls,
                    toolCallId: message.toolCallId,
                    reasoning: message.reasoning
                )
            }
        }
    }

    private static func isRetryableError(_ error: Error) -> Bool {
        if let llmError = error as? LLMError {
            return llmError.isRetryable
        }

        let errorString = error.localizedDescription.lowercased()

        if errorString.contains("rate limit") || errorString.contains("too many requests") {
            return true
        }

        if errorString.contains("network") || errorString.contains("timeout") ||
           errorString.contains("connection") || errorString.contains("temporarily unavailable") {
            return true
        }

        if errorString.contains("500") || errorString.contains("502") ||
           errorString.contains("503") || errorString.contains("504") {
            return true
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet,
                 .cannotConnectToHost, .cannotFindHost:
                return true
            default:
                break
            }
        }

        return false
    }
}
