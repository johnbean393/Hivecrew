//
//  OpenAICompatibleClient+RawHTTP.swift
//  HivecrewLLM
//
//  Raw HTTP fallback methods for OpenAICompatibleClient
//

import Foundation

// MARK: - Raw HTTP Fallback (for providers with non-standard responses)

extension OpenAICompatibleClient {
    
    /// Raw HTTP-based streaming chat method with reasoning and content callbacks
    /// Streams tokens as they arrive
    public func chatRawStreaming(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        onReasoningUpdate: ReasoningStreamCallback?,
        onContentUpdate: ContentStreamCallback? = nil
    ) async throws -> LLMResponse {
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
        
        // Enable reasoning tokens by default for OpenRouter
        if configuration.isOpenRouter {
            body["reasoning"] = ["enabled": true]
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        // Use URLSession bytes for streaming
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        
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
            
            // Check for payload too large (413) errors
            if httpResponse.statusCode == 413 || errorBody.lowercased().contains("oversized payload") {
                throw LLMError.payloadTooLarge(message: errorBody)
            }
            
            throw LLMError.unknown(message: "HTTP \(httpResponse.statusCode): \(errorBody)")
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
        
        for try await byte in bytes {
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
                
                // SSE format: "data: {...}" or "data: [DONE]"
                if line.hasPrefix("data: ") {
                    let jsonString = String(line.dropFirst(6))
                    
                    if jsonString == "[DONE]" {
                        break
                    }
                    
                    if let jsonData = jsonString.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                        
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
                                    // Content delta
                                    if let contentDelta = delta["content"] as? String {
                                        accumulatedContent += contentDelta
                                        // Call callback with accumulated content
                                        onContentUpdate?(accumulatedContent)
                                    }
                                    
                                    // Reasoning delta (OpenRouter streams reasoning in delta.reasoning)
                                    if let reasoningDelta = delta["reasoning"] as? String {
                                        accumulatedReasoning += reasoningDelta
                                        // Call callback with accumulated reasoning
                                        onReasoningUpdate?(accumulatedReasoning)
                                    }
                                    
                                    // Tool call deltas
                                    if let toolCallDeltas_arr = delta["tool_calls"] as? [[String: Any]] {
                                        for tcDelta in toolCallDeltas_arr {
                                            let index = tcDelta["index"] as? Int ?? 0
                                            let indexStr = String(index)
                                            
                                            // Initialize or update the tool call
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
        
        // Convert accumulated tool call deltas to LLMToolCall array
        let sortedToolCalls = toolCallDeltas.sorted { Int($0.key) ?? 0 < Int($1.key) ?? 0 }
        toolCalls = sortedToolCalls.compactMap { (_, value) in
            guard !value.id.isEmpty, !value.name.isEmpty else { return nil }
            return LLMToolCall(
                id: value.id,
                type: "function",
                function: LLMFunctionCall(name: value.name, arguments: value.arguments)
            )
        }
        
        // Build final response
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
    }
    
    /// Raw HTTP-based chat method that bypasses the OpenAI library
    /// Use this if the library fails to parse responses
    public func chatRaw(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?
    ) async throws -> LLMResponse {
        let endpoint = buildChatURL()
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let orgId = configuration.organizationId {
            request.setValue(orgId, forHTTPHeaderField: "OpenAI-Organization")
        }
        request.timeoutInterval = configuration.timeoutInterval
        
        // Build request body
        var body: [String: Any] = [
            "model": configuration.model,
            "messages": try messages.map { try convertMessageToDict($0) }
        ]
        
        if let tools = tools, !tools.isEmpty {
            body["tools"] = tools.map { convertToolToDict($0) }
        }
        
        // Enable reasoning tokens by default for OpenRouter
        if configuration.isOpenRouter {
            body["reasoning"] = ["enabled": true]
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.unknown(message: "Invalid response type")
        }
        
        // Log raw response for debugging
        if let responseString = String(data: data, encoding: .utf8) {
            print("[HivecrewLLM] Raw response (\(httpResponse.statusCode)): \(String(responseString.prefix(500)))")
        }
        
        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "No response body"
            
            // Check for payload too large (413) errors
            if httpResponse.statusCode == 413 || body.lowercased().contains("oversized payload") {
                throw LLMError.payloadTooLarge(message: body)
            }
            
            throw LLMError.unknown(message: "HTTP \(httpResponse.statusCode): \(body)")
        }
        
        return try parseRawChatResponse(data)
    }
    
    func buildChatURL() -> URL {
        if let baseURL = configuration.baseURL {
            return baseURL.appendingPathComponent("chat/completions")
        } else {
            return URL(string: "https://api.openai.com/v1/chat/completions")!
        }
    }
    
    func convertMessageToDict(_ message: LLMMessage) throws -> [String: Any] {
        var dict: [String: Any] = ["role": message.role.rawValue]
        
        // Handle content
        let hasImages = message.content.contains { content in
            switch content {
            case .imageBase64, .imageURL: return true
            default: return false
            }
        }
        
        if hasImages {
            var contentParts: [[String: Any]] = []
            for content in message.content {
                switch content {
                case .text(let text):
                    contentParts.append(["type": "text", "text": text])
                case .imageBase64(let data, let mimeType):
                    contentParts.append([
                        "type": "image_url",
                        "image_url": ["url": "data:\(mimeType);base64,\(data)"]
                    ])
                case .imageURL(let url):
                    contentParts.append([
                        "type": "image_url",
                        "image_url": ["url": url.absoluteString]
                    ])
                case .toolResult:
                    break
                }
            }
            dict["content"] = contentParts
        } else if message.role == .tool {
            // Tool messages need to extract content from .toolResult, not .text
            var resultContent = ""
            for content in message.content {
                if case .toolResult(_, let c) = content {
                    resultContent = c
                    break
                }
            }
            dict["content"] = resultContent
        } else {
            dict["content"] = message.textContent
        }
        
        // Handle tool calls for assistant messages
        if message.role == .assistant, let toolCalls = message.toolCalls, !toolCalls.isEmpty {
            dict["tool_calls"] = toolCalls.map { call in
                [
                    "id": call.id,
                    "type": "function",
                    "function": [
                        "name": call.function.name,
                        "arguments": call.function.arguments
                    ]
                ]
            }
        }
        
        // Handle tool call ID for tool messages
        if message.role == .tool, let toolCallId = message.toolCallId {
            dict["tool_call_id"] = toolCallId
        }
        
        return dict
    }
    
    func convertToolToDict(_ tool: LLMToolDefinition) -> [String: Any] {
        return [
            "type": "function",
            "function": [
                "name": tool.function.name,
                "description": tool.function.description,
                "parameters": tool.function.parameters
            ]
        ]
    }
    
    func parseRawChatResponse(_ data: Data) throws -> LLMResponse {
        // Trim leading whitespace from response (some providers like OpenRouter add leading newlines)
        let trimmedData: Data
        if let string = String(data: data, encoding: .utf8) {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            trimmedData = trimmed.data(using: .utf8) ?? data
        } else {
            trimmedData = data
        }
        
        guard let json = try JSONSerialization.jsonObject(with: trimmedData) as? [String: Any] else {
            throw LLMError.decodingError(underlying: NSError(domain: "LLM", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON"]))
        }
        
        let id = json["id"] as? String ?? ""
        let model = json["model"] as? String ?? ""
        let created = json["created"] as? Int ?? 0
        
        var choices: [LLMResponseChoice] = []
        if let choicesArray = json["choices"] as? [[String: Any]] {
            for choice in choicesArray {
                let index = choice["index"] as? Int ?? 0
                let finishReasonStr = choice["finish_reason"] as? String
                
                guard let messageDict = choice["message"] as? [String: Any] else { continue }
                
                let content = messageDict["content"] as? String ?? ""
                
                // Parse reasoning tokens (OpenRouter returns these in the "reasoning" field)
                let reasoning = messageDict["reasoning"] as? String
                
                // Parse tool calls
                var toolCalls: [LLMToolCall]? = nil
                if let toolCallsArray = messageDict["tool_calls"] as? [[String: Any]] {
                    toolCalls = toolCallsArray.compactMap { tc in
                        guard let tcId = tc["id"] as? String,
                              let function = tc["function"] as? [String: Any],
                              let name = function["name"] as? String,
                              let args = function["arguments"] as? String else { return nil }
                        return LLMToolCall(
                            id: tcId,
                            type: "function",
                            function: LLMFunctionCall(name: name, arguments: args)
                        )
                    }
                }
                
                let message = LLMMessage(
                    role: .assistant,
                    content: [.text(content)],
                    name: nil,
                    toolCalls: toolCalls,
                    toolCallId: nil,
                    reasoning: reasoning
                )
                
                let finishReason: LLMFinishReason?
                switch finishReasonStr {
                case "stop": finishReason = .stop
                case "length": finishReason = .length
                case "tool_calls": finishReason = .toolCalls
                case "content_filter": finishReason = .contentFilter
                default: finishReason = .unknown
                }
                
                choices.append(LLMResponseChoice(index: index, message: message, finishReason: finishReason))
            }
        }
        
        var usage: LLMUsage? = nil
        if let usageDict = json["usage"] as? [String: Any] {
            usage = LLMUsage(
                promptTokens: usageDict["prompt_tokens"] as? Int ?? 0,
                completionTokens: usageDict["completion_tokens"] as? Int ?? 0,
                totalTokens: usageDict["total_tokens"] as? Int ?? 0
            )
        }
        
        return LLMResponse(
            id: id,
            model: model,
            created: Date(timeIntervalSince1970: TimeInterval(created)),
            choices: choices,
            usage: usage
        )
    }
}
