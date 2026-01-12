//
//  OpenAICompatibleClient+RawHTTP.swift
//  HivecrewLLM
//
//  Raw HTTP fallback methods for OpenAICompatibleClient
//

import Foundation

// MARK: - Raw HTTP Fallback (for providers with non-standard responses)

extension OpenAICompatibleClient {
    
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
            throw LLMError.unknown(message: "HTTP \(httpResponse.statusCode): \(body)")
        }
        
        return try parseRawChatResponse(data)
    }
    
    func buildChatURL() -> URL {
        if let baseURL = configuration.baseURL {
            var path = baseURL.path
            while path.hasSuffix("/") {
                path = String(path.dropLast())
            }
            if path.hasSuffix("/v1") {
                return baseURL.appendingPathComponent("chat/completions")
            } else {
                return baseURL.appendingPathComponent("v1/chat/completions")
            }
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
                    toolCallId: nil
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
