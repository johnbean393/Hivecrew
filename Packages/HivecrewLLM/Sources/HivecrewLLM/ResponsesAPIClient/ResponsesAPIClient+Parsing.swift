import Foundation

extension ResponsesAPIClient {
    func parseNonStreamingResponse(_ data: Data) throws -> LLMResponse {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.decodingError(
                underlying: NSError(
                    domain: "HivecrewLLM.Responses",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid JSON response"]
                )
            )
        }

        return parseFinalResponseEnvelope(json)
    }

    func parseStreamingResponse(
        bytes: URLSession.AsyncBytes,
        onReasoningUpdate: ReasoningStreamCallback?,
        onContentUpdate: ContentStreamCallback?
    ) async throws -> LLMResponse {
        var lineBuffer = Data()

        var responseId = ""
        var responseModel = configuration.model
        var accumulatedText = ""
        var accumulatedReasoning = ""
        var usage: LLMUsage?
        var finishReason: LLMFinishReason? = .stop
        var toolCallsByCallID: [String: (name: String, arguments: String)] = [:]

        for try await byte in bytes {
            if byte == 0x0A {
                guard let line = String(data: lineBuffer, encoding: .utf8) else {
                    lineBuffer.removeAll()
                    continue
                }
                lineBuffer.removeAll()

                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                guard trimmed.hasPrefix("data:") else { continue }

                let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard payload != "[DONE]" else { break }
                guard let eventData = payload.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any] else {
                    continue
                }

                if let error = event["error"] as? [String: Any] {
                    let message = error["message"] as? String ?? "Unknown error"
                    let type = error["type"] as? String ?? "api_error"
                    throw LLMError.apiError(statusCode: 0, message: "\(type): \(message)")
                }

                if let type = event["type"] as? String {
                    switch type {
                    case "codex.rate_limits":
                        if let snapshot = parseCodexRateLimitSnapshot(from: event) {
                            _ = CodexRateLimitStore.store(providerId: configuration.id, snapshot: snapshot)
                        }
                    case "response.created":
                        if let response = event["response"] as? [String: Any] {
                            responseId = response["id"] as? String ?? responseId
                            responseModel = response["model"] as? String ?? responseModel
                        }
                    case "response.output_text.delta":
                        let delta = event["delta"] as? String ?? ""
                        if !delta.isEmpty {
                            accumulatedText += delta
                            onContentUpdate?(accumulatedText)
                        }
                    case "response.output_text.done":
                        if let text = event["text"] as? String, !text.isEmpty {
                            accumulatedText = mergeStreamedText(current: accumulatedText, candidate: text)
                            onContentUpdate?(accumulatedText)
                        }
                    case "response.reasoning_text.delta", "response.reasoning.delta":
                        let delta = event["delta"] as? String ?? ""
                        if !delta.isEmpty {
                            accumulatedReasoning += delta
                            onReasoningUpdate?(accumulatedReasoning)
                        }
                    case "response.reasoning_text.done", "response.reasoning.done":
                        if let text = event["text"] as? String, !text.isEmpty {
                            accumulatedReasoning = mergeStreamedText(current: accumulatedReasoning, candidate: text)
                            onReasoningUpdate?(accumulatedReasoning)
                        }
                    case "response.content_part.done":
                        if let part = event["part"] as? [String: Any] {
                            let partType = part["type"] as? String
                            if (partType == "output_text" || partType == "text"),
                               let text = part["text"] as? String, !text.isEmpty {
                                accumulatedText = mergeStreamedText(current: accumulatedText, candidate: text)
                                onContentUpdate?(accumulatedText)
                            } else if (partType == "reasoning" || partType == "reasoning_text"),
                                      let text = part["text"] as? String, !text.isEmpty {
                                accumulatedReasoning = mergeStreamedText(current: accumulatedReasoning, candidate: text)
                                onReasoningUpdate?(accumulatedReasoning)
                            }
                        }
                    case "response.function_call_arguments.delta":
                        let callID = (event["call_id"] as? String)
                            ?? (event["item_id"] as? String)
                            ?? "call_\(toolCallsByCallID.count)"
                        var current = toolCallsByCallID[callID] ?? (name: event["name"] as? String ?? "", arguments: "")
                        if let name = event["name"] as? String, !name.isEmpty {
                            current.name = name
                        }
                        if let delta = event["delta"] as? String {
                            current.arguments += delta
                        }
                        toolCallsByCallID[callID] = current
                    case "response.function_call_arguments.done":
                        let callID = (event["call_id"] as? String)
                            ?? (event["item_id"] as? String)
                            ?? "call_\(toolCallsByCallID.count)"
                        var current = toolCallsByCallID[callID] ?? (name: event["name"] as? String ?? "", arguments: "")
                        if let name = event["name"] as? String, !name.isEmpty {
                            current.name = name
                        }
                        if let arguments = event["arguments"] as? String, !arguments.isEmpty {
                            current.arguments = arguments
                        }
                        toolCallsByCallID[callID] = current
                    case "response.output_item.added":
                        if let item = event["item"] as? [String: Any],
                           (item["type"] as? String) == "function_call" {
                            let callID = (item["call_id"] as? String)
                                ?? (item["id"] as? String)
                                ?? "call_\(toolCallsByCallID.count)"
                            var current = toolCallsByCallID[callID] ?? (name: "", arguments: "")
                            current.name = (item["name"] as? String) ?? current.name
                            if let args = item["arguments"] as? String, !args.isEmpty {
                                current.arguments = args
                            }
                            toolCallsByCallID[callID] = current
                        }
                    case "response.output_item.done":
                        if let item = event["item"] as? [String: Any],
                           (item["type"] as? String) == "function_call" {
                            let callID = (item["call_id"] as? String)
                                ?? (item["id"] as? String)
                                ?? "call_\(toolCallsByCallID.count)"
                            var current = toolCallsByCallID[callID] ?? (name: "", arguments: "")
                            current.name = (item["name"] as? String) ?? current.name
                            if let args = item["arguments"] as? String, !args.isEmpty {
                                current.arguments = args
                            }
                            toolCallsByCallID[callID] = current
                        }
                    case "response.completed":
                        if let response = event["response"] as? [String: Any] {
                            return buildCompletedStreamingResponse(
                                response,
                                fallbackText: accumulatedText,
                                fallbackReasoning: accumulatedReasoning,
                                fallbackToolCallsByCallID: toolCallsByCallID
                            )
                        }
                    case "response.failed":
                        let message = (event["error"] as? [String: Any])?["message"] as? String ?? "Response failed"
                        throw LLMError.unknown(message: message)
                    default:
                        if event["id"] != nil, event["output"] != nil {
                            let parsed = parseFinalResponseEnvelope(event)
                            responseId = parsed.id
                            responseModel = parsed.model
                            accumulatedText = parsed.text ?? accumulatedText
                            accumulatedReasoning = parsed.reasoning ?? accumulatedReasoning
                            usage = parsed.usage
                            finishReason = parsed.finishReason

                            if let streamedText = parsed.text {
                                onContentUpdate?(streamedText)
                            }
                            if let streamedReasoning = parsed.reasoning {
                                onReasoningUpdate?(streamedReasoning)
                            }
                        }
                    }
                }
            } else {
                lineBuffer.append(byte)
            }
        }

        let toolCalls = toolCallsByCallID.map { key, value in
            LLMToolCall(
                id: key,
                type: "function",
                function: LLMFunctionCall(name: value.name, arguments: value.arguments)
            )
        }
        .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }

        let message = LLMMessage(
            role: .assistant,
            content: [.text(accumulatedText)],
            name: nil,
            toolCalls: toolCalls.isEmpty ? nil : toolCalls,
            toolCallId: nil,
            reasoning: accumulatedReasoning.isEmpty ? nil : accumulatedReasoning
        )

        return LLMResponse(
            id: responseId,
            model: responseModel,
            created: Date(),
            choices: [LLMResponseChoice(index: 0, message: message, finishReason: finishReason)],
            usage: usage
        )
    }

    func parseFinalResponseEnvelope(_ envelope: [String: Any]) -> LLMResponse {
        let responseID = envelope["id"] as? String ?? ""
        let model = envelope["model"] as? String ?? configuration.model

        var textFragments: [String] = []
        var reasoningFragments: [String] = []
        var toolCalls: [LLMToolCall] = []

        if let output = envelope["output"] as? [[String: Any]] {
            for item in output {
                if let type = item["type"] as? String {
                    switch type {
                    case "message":
                        if let contentItems = item["content"] as? [[String: Any]] {
                            for contentItem in contentItems {
                                let contentType = contentItem["type"] as? String
                                if contentType == "output_text" || contentType == "text" {
                                    if let text = contentItem["text"] as? String {
                                        textFragments.append(text)
                                    }
                                } else if contentType == "reasoning" || contentType == "reasoning_text" {
                                    if let text = contentItem["text"] as? String {
                                        reasoningFragments.append(text)
                                    }
                                    if let summary = contentItem["summary"] as? String {
                                        reasoningFragments.append(summary)
                                    }
                                }
                            }
                        }
                    case "function_call":
                        let callID = (item["call_id"] as? String) ?? (item["id"] as? String) ?? UUID().uuidString
                        let name = item["name"] as? String ?? ""
                        let arguments = item["arguments"] as? String ?? "{}"
                        if !name.isEmpty {
                            toolCalls.append(
                                LLMToolCall(
                                    id: callID,
                                    type: "function",
                                    function: LLMFunctionCall(name: name, arguments: arguments)
                                )
                            )
                        }
                    default:
                        continue
                    }
                }
            }
        }

        if textFragments.isEmpty, let outputText = envelope["output_text"] as? String, !outputText.isEmpty {
            textFragments = [outputText]
        }

        let usage = parseUsage(envelope["usage"] as? [String: Any])
        let message = LLMMessage(
            role: .assistant,
            content: [.text(textFragments.joined())],
            name: nil,
            toolCalls: toolCalls.isEmpty ? nil : toolCalls,
            toolCallId: nil,
            reasoning: reasoningFragments.isEmpty ? nil : reasoningFragments.joined()
        )

        let finishReason = toolCalls.isEmpty ? LLMFinishReason.stop : LLMFinishReason.toolCalls

        return LLMResponse(
            id: responseID,
            model: model,
            created: Date(),
            choices: [LLMResponseChoice(index: 0, message: message, finishReason: finishReason)],
            usage: usage
        )
    }

    func buildCompletedStreamingResponse(
        _ envelope: [String: Any],
        fallbackText: String,
        fallbackReasoning: String,
        fallbackToolCallsByCallID: [String: (name: String, arguments: String)]
    ) -> LLMResponse {
        let parsed = parseFinalResponseEnvelope(envelope)

        let mergedText = mergeStreamedText(
            current: parsed.text ?? "",
            candidate: fallbackText
        )
        let mergedReasoning = mergeStreamedText(
            current: parsed.reasoning ?? "",
            candidate: fallbackReasoning
        )
        let mergedToolCalls = mergeToolCalls(
            primary: parsed.toolCalls,
            fallbackByCallID: fallbackToolCallsByCallID
        )

        let message = LLMMessage(
            role: .assistant,
            content: [.text(mergedText)],
            name: parsed.message?.name,
            toolCalls: mergedToolCalls.isEmpty ? nil : mergedToolCalls,
            toolCallId: nil,
            reasoning: mergedReasoning.isEmpty ? nil : mergedReasoning
        )

        let finishReason: LLMFinishReason? = mergedToolCalls.isEmpty ? parsed.finishReason : .toolCalls

        return LLMResponse(
            id: parsed.id,
            model: parsed.model,
            created: parsed.created,
            choices: [LLMResponseChoice(index: 0, message: message, finishReason: finishReason)],
            usage: parsed.usage
        )
    }

    func mergeStreamedText(current: String, candidate: String) -> String {
        guard !candidate.isEmpty else { return current }
        guard !current.isEmpty else { return candidate }
        if candidate == current || candidate.hasPrefix(current) {
            return candidate
        }
        return current
    }

    func mergeToolCalls(
        primary: [LLMToolCall]?,
        fallbackByCallID: [String: (name: String, arguments: String)]
    ) -> [LLMToolCall] {
        if let primary, !primary.isEmpty {
            return primary
        }

        return fallbackByCallID
            .compactMap { key, value in
                guard !value.name.isEmpty else { return nil }
                return LLMToolCall(
                    id: key,
                    type: "function",
                    function: LLMFunctionCall(name: value.name, arguments: value.arguments)
                )
            }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    func parseUsage(_ usageDict: [String: Any]?) -> LLMUsage? {
        guard let usageDict else { return nil }

        let promptTokens = (usageDict["prompt_tokens"] as? Int)
            ?? (usageDict["input_tokens"] as? Int)
            ?? 0
        let completionTokens = (usageDict["completion_tokens"] as? Int)
            ?? (usageDict["output_tokens"] as? Int)
            ?? 0
        let totalTokens = (usageDict["total_tokens"] as? Int)
            ?? (promptTokens + completionTokens)

        // Reasoning tokens (Anthropic: output_tokens_details.reasoning_tokens, OpenAI: completion_tokens_details.reasoning_tokens)
        let reasoningTokens: Int = {
            if let details = usageDict["output_tokens_details"] as? [String: Any],
               let r = details["reasoning_tokens"] as? Int { return r }
            if let details = usageDict["completion_tokens_details"] as? [String: Any],
               let r = details["reasoning_tokens"] as? Int { return r }
            return 0
        }()

        // Cache tokens (Anthropic naming)
        let cacheReadTokens = (usageDict["cache_read_input_tokens"] as? Int)
            ?? (usageDict["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int
            ?? 0
        let cacheCreationTokens = usageDict["cache_creation_input_tokens"] as? Int ?? 0

        return LLMUsage(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: totalTokens,
            reasoningTokens: reasoningTokens,
            cacheReadTokens: cacheReadTokens,
            cacheCreationTokens: cacheCreationTokens
        )
    }
}

extension ResponsesAPIClient {
    func classifyHTTPError(statusCode: Int, body: String) -> LLMError {
        if statusCode == 401 || statusCode == 403 {
            return .authenticationError(message: body)
        }
        if statusCode == 429 {
            return .rateLimitError(retryAfter: nil)
        }
        if statusCode == 413 {
            return .payloadTooLarge(message: body)
        }
        if let classified = classifyContextOrPayloadError(message: body) {
            return classified
        }
        return .apiError(statusCode: statusCode, message: body)
    }

    func classifyContextOrPayloadError(message: String) -> LLMError? {
        let normalized = message.lowercased()

        if normalized.contains("oversized payload")
            || normalized.contains("payload too large")
            || normalized.contains("request entity too large") {
            return .payloadTooLarge(message: message)
        }

        if let contextInfo = ContextLimitErrorParser.parse(message: message) {
            return .contextLimitExceeded(
                message: message,
                maxInputTokens: contextInfo.maxInputTokens,
                requestedTokens: contextInfo.requestedTokens
            )
        }

        return nil
    }
}
