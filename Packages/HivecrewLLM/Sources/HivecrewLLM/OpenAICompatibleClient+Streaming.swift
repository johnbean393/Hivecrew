//
//  OpenAICompatibleClient+Streaming.swift
//  HivecrewLLM
//
//  Streaming raw HTTP chat support for OpenAI-compatible providers
//

import Foundation

extension OpenAICompatibleClient {
    /// Raw HTTP-based streaming chat method with reasoning and content callbacks
    /// Streams tokens as they arrive
    public func chatRawStreaming(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        onReasoningUpdate: ReasoningStreamCallback?,
        onContentUpdate: ContentStreamCallback? = nil
    ) async throws -> LLMResponse {
        do {
            let endpoint = buildChatURL()
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let orgId = configuration.organizationId {
                request.setValue(orgId, forHTTPHeaderField: "OpenAI-Organization")
            }
            request.timeoutInterval = configuration.timeoutInterval

            // Build request body with streaming enabled
            var body: [String: Any] = [
                "model": configuration.model,
                "messages": try messages.map { try convertMessageToDict($0) },
                "stream": true
            ]

            if let tools = tools, !tools.isEmpty {
                body["tools"] = tools.map { convertToolToDict($0) }
            }

            if configuration.reasoningEnabled == true {
                body["reasoning"] = ["enabled": true]
            }

            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            // Use dedicated URLSession with request + resource deadlines.
            let (bytes, response) = try await urlSession.bytes(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw LLMError.unknown(message: "Invalid response type")
            }

            guard httpResponse.statusCode == 200 else {
                // For errors, we need to collect all bytes first
                var errorData = Data()
                for try await byte in bytes {
                    errorData.append(byte)
                }
                let errorBody = String(data: errorData, encoding: .utf8) ?? "No response body"

                throw classifyHTTPError(statusCode: httpResponse.statusCode, body: errorBody)
            }

            // Parse SSE stream
            var accumulatedContent = ""
            var accumulatedReasoning = ""
            var responseId = ""
            var responseModel = ""
            var finishReasonStr: String? = nil
            var toolCalls: [LLMToolCall] = []
            var toolCallDeltas: [String: (id: String, name: String, arguments: String)] = [:]
            var usage: LLMUsage? = nil

            var lineBuffer = Data()
            let streamStart = Date()

            for try await byte in bytes {
                // Absolute wall-clock guard so keepalive bytes can't stretch forever.
                if Date().timeIntervalSince(streamStart) > configuration.timeoutInterval {
                    throw LLMError.timeout
                }

                // Check for newline (0x0A)
                if byte == 0x0A {
                    // Decode the line buffer as UTF-8
                    guard let lineString = String(data: lineBuffer, encoding: .utf8) else {
                        lineBuffer.removeAll()
                        continue
                    }

                    // Process the line
                    let line = lineString.trimmingCharacters(in: .whitespaces)
                    lineBuffer.removeAll()

                    if line.isEmpty {
                        continue
                    }

                    // SSE format: "data: {...}" or "data: [DONE]" or "event: ..."
                    // Check for SSE error events first
                    if line.hasPrefix("event: error") || line.hasPrefix("event:error") {
                        // Next data line will contain error details
                        print("[HivecrewLLM] SSE error event received")
                        continue
                    }

                    if line.hasPrefix("data: ") {
                        let jsonString = String(line.dropFirst(6))

                        if jsonString == "[DONE]" {
                            break
                        }

                        // Check for error responses in the data
                        if let jsonData = jsonString.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {

                            // Check if this is an error response
                            if let error = json["error"] as? [String: Any] {
                                let errorMessage = error["message"] as? String ?? "Unknown error"
                                let errorType = error["type"] as? String ?? "api_error"
                                let rawPayload = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
                                let maxPayloadLength = 2000
                                let payloadPreview: String
                                if rawPayload.count > maxPayloadLength {
                                    payloadPreview = String(rawPayload.prefix(maxPayloadLength)) + "...(truncated)"
                                } else {
                                    payloadPreview = rawPayload
                                }
                                let payloadNote = payloadPreview.isEmpty ? "" : " | raw_payload: \(payloadPreview)"
                                print("[HivecrewLLM] SSE stream error: \(errorType) - \(errorMessage)\(payloadNote)")
                                let mergedMessage = "\(errorType): \(errorMessage)\(payloadNote)"
                                if let classified = classifyContextOrPayloadError(message: mergedMessage) {
                                    throw classified
                                }
                                throw LLMError.apiError(statusCode: 0, message: mergedMessage)
                            }

                            // Extract response metadata
                            if let id = json["id"] as? String, !id.isEmpty {
                                responseId = id
                            }
                            if let model = json["model"] as? String, !model.isEmpty {
                                responseModel = model
                            }

                            // Extract usage (sometimes included in final chunk)
                            if let usageDict = json["usage"] as? [String: Any] {
                                usage = LLMUsage(
                                    promptTokens: usageDict["prompt_tokens"] as? Int ?? 0,
                                    completionTokens: usageDict["completion_tokens"] as? Int ?? 0,
                                    totalTokens: usageDict["total_tokens"] as? Int ?? 0
                                )
                            }

                            // Process choices
                            if let choices = json["choices"] as? [[String: Any]] {
                                for choice in choices {
                                    // Check finish reason
                                    if let reason = choice["finish_reason"] as? String {
                                        finishReasonStr = reason
                                    }

                                    // Process delta (streaming chunk)
                                    if let delta = choice["delta"] as? [String: Any] {
                                        if let contentDelta = delta["content"] as? String {
                                            accumulatedContent += contentDelta
                                            onContentUpdate?(accumulatedContent)
                                        }

                                        if let reasoningDelta = delta["reasoning"] as? String {
                                            accumulatedReasoning += reasoningDelta
                                            onReasoningUpdate?(accumulatedReasoning)
                                        }

                                        if let toolCallDeltasArr = delta["tool_calls"] as? [[String: Any]] {
                                            for tcDelta in toolCallDeltasArr {
                                                let index = tcDelta["index"] as? Int ?? 0
                                                let indexStr = String(index)

                                                var current = toolCallDeltas[indexStr] ?? (id: "", name: "", arguments: "")

                                                if let id = tcDelta["id"] as? String {
                                                    current.id = id
                                                }
                                                if let function = tcDelta["function"] as? [String: Any] {
                                                    if let name = function["name"] as? String {
                                                        current.name = name
                                                    }
                                                    if let args = function["arguments"] as? String {
                                                        current.arguments += args
                                                    }
                                                }

                                                toolCallDeltas[indexStr] = current
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                } else {
                    lineBuffer.append(byte)
                }
            }

            let sortedToolCalls = toolCallDeltas.sorted { Int($0.key) ?? 0 < Int($1.key) ?? 0 }
            toolCalls = sortedToolCalls.compactMap { (_, value) in
                guard !value.id.isEmpty, !value.name.isEmpty else { return nil }
                return LLMToolCall(
                    id: value.id,
                    type: "function",
                    function: LLMFunctionCall(name: value.name, arguments: value.arguments)
                )
            }

            let finishReason: LLMFinishReason?
            switch finishReasonStr {
            case "stop": finishReason = .stop
            case "length": finishReason = .length
            case "tool_calls": finishReason = .toolCalls
            case "content_filter": finishReason = .contentFilter
            default: finishReason = .unknown
            }

            let message = LLMMessage(
                role: .assistant,
                content: [.text(accumulatedContent)],
                name: nil,
                toolCalls: toolCalls.isEmpty ? nil : toolCalls,
                toolCallId: nil,
                reasoning: accumulatedReasoning.isEmpty ? nil : accumulatedReasoning
            )

            let choice = LLMResponseChoice(
                index: 0,
                message: message,
                finishReason: finishReason
            )

            return LLMResponse(
                id: responseId,
                model: responseModel,
                created: Date(),
                choices: [choice],
                usage: usage
            )
        } catch let llmError as LLMError {
            throw llmError
        } catch is CancellationError {
            throw LLMError.cancelled
        } catch let urlError as URLError {
            switch urlError.code {
            case .timedOut:
                throw LLMError.timeout
            case .cancelled:
                throw LLMError.cancelled
            default:
                throw LLMError.networkError(underlying: urlError)
            }
        } catch {
            throw LLMError.unknown(message: error.localizedDescription)
        }
    }
}
