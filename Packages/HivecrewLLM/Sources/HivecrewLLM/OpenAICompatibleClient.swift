//
//  OpenAICompatibleClient.swift
//  HivecrewLLM
//
//  OpenAI-compatible LLM client implementation using MacPaw's OpenAI library
//

import Foundation
import OpenAI

// Type aliases for cleaner code
private typealias MessageParam = ChatQuery.ChatCompletionMessageParam
private typealias TextParam = MessageParam.ContentPartTextParam
private typealias ImageParam = MessageParam.ContentPartImageParam
private typealias ToolCallParam = MessageParam.AssistantMessageParam.ToolCallParam

/// Response from /v1/models endpoint
private struct ModelsResponse: Decodable {
    let data: [ModelInfo]
    
    struct ModelInfo: Decodable {
        let id: String
    }
}

/// LLM client implementation using the MacPaw OpenAI library
///
/// This client supports:
/// - Standard OpenAI API
/// - Azure OpenAI
/// - Any OpenAI-compatible API (via custom baseURL)
/// - Vision/image inputs
/// - Function/tool calling
public final class OpenAICompatibleClient: LLMClientProtocol, @unchecked Sendable {
    public let configuration: LLMConfiguration
    
    private let openAI: OpenAI
    
    public init(configuration: LLMConfiguration) {
        self.configuration = configuration
        
        // Build OpenAI configuration
        var openAIConfig: OpenAI.Configuration
        
        if let baseURL = configuration.baseURL {
            // Custom endpoint configuration
            openAIConfig = OpenAI.Configuration(
                token: configuration.apiKey,
                organizationIdentifier: configuration.organizationId,
                host: baseURL.host ?? "api.openai.com",
                port: baseURL.port ?? 443,
                scheme: baseURL.scheme ?? "https",
                timeoutInterval: configuration.timeoutInterval
            )
        } else {
            // Default OpenAI configuration
            openAIConfig = OpenAI.Configuration(
                token: configuration.apiKey,
                organizationIdentifier: configuration.organizationId,
                timeoutInterval: configuration.timeoutInterval
            )
        }
        
        self.openAI = OpenAI(configuration: openAIConfig)
    }
    
    public func chat(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?
    ) async throws -> LLMResponse {
        // Convert messages to OpenAI format
        let openAIMessages = try messages.map { try convertMessage($0) }
        // Convert tools to OpenAI format
        let openAITools = tools?.compactMap { convertTool($0) }
        // Build the query
        let query = ChatQuery(
            messages: openAIMessages,
            model: configuration.model,
            tools: openAITools
        )
        
        do {
            let result = try await openAI.chats(query: query)
            return try convertResponse(result)
        } catch let error as URLError {
            if error.code == .timedOut {
                throw LLMError.timeout
            } else if error.code == .cancelled {
                throw LLMError.cancelled
            }
            throw LLMError.networkError(underlying: error)
        } catch let error as DecodingError {
            // Extract detailed decoding error info
            let detailedMessage = extractDecodingErrorDetails(error)
            print("[HivecrewLLM] Decoding error with library, trying raw HTTP fallback: \(detailedMessage)")
            
            // Fall back to raw HTTP request which has more lenient parsing
            return try await chatRaw(messages: messages, tools: tools)
        } catch {
            // Try to extract more info from the error
            let errorMessage = error.localizedDescription
            print("[HivecrewLLM] Chat error: \(errorMessage)")
            if errorMessage.contains("401") || errorMessage.contains("unauthorized") {
                throw LLMError.authenticationError(message: errorMessage)
            } else if errorMessage.contains("429") || errorMessage.contains("rate limit") {
                throw LLMError.rateLimitError(retryAfter: nil)
            }
            throw LLMError.unknown(message: errorMessage)
        }
    }
    
    /// Extract detailed information from a DecodingError
    private func extractDecodingErrorDetails(_ error: DecodingError) -> String {
        switch error {
        case .typeMismatch(let type, let context):
            let path = context.codingPath.map { $0.stringValue }.joined(separator: ".")
            return "Type mismatch: expected \(type) at path '\(path)'. \(context.debugDescription)"
        case .valueNotFound(let type, let context):
            let path = context.codingPath.map { $0.stringValue }.joined(separator: ".")
            return "Value not found: expected \(type) at path '\(path)'. \(context.debugDescription)"
        case .keyNotFound(let key, let context):
            let path = context.codingPath.map { $0.stringValue }.joined(separator: ".")
            return "Key not found: '\(key.stringValue)' at path '\(path)'. \(context.debugDescription)"
        case .dataCorrupted(let context):
            let path = context.codingPath.map { $0.stringValue }.joined(separator: ".")
            return "Data corrupted at path '\(path)'. \(context.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }
    
    public func testConnection() async throws -> Bool {
        // Send a simple message to test the connection
        let testMessages: [LLMMessage] = [
            .user("Hello")
        ]
        
        let _ = try await chat(messages: testMessages, tools: nil)
        return true
    }
    
    public func listModels() async throws -> [String] {
        // Build the models endpoint URL manually to handle base URLs ending with /v1
        let modelsURL = buildModelsURL()
        
        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let orgId = configuration.organizationId {
            request.setValue(orgId, forHTTPHeaderField: "OpenAI-Organization")
        }
        request.timeoutInterval = configuration.timeoutInterval
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw LLMError.unknown(message: "Invalid response type")
            }
            
            guard httpResponse.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? "No response body"
                throw LLMError.unknown(message: "HTTP \(httpResponse.statusCode): \(body)")
            }
            
            // Parse the response
            let modelsResponse = try JSONDecoder().decode(ModelsResponse.self, from: data)
            return modelsResponse.data
                .map { $0.id }
                .sorted()
        } catch let error as LLMError {
            throw error
        } catch let error as URLError {
            if error.code == .timedOut {
                throw LLMError.timeout
            }
            throw LLMError.networkError(underlying: error)
        } catch {
            throw LLMError.unknown(message: error.localizedDescription)
        }
    }
    
    /// Build the models endpoint URL, handling base URLs that end with /v1 or /v1/
    private func buildModelsURL() -> URL {
        if let baseURL = configuration.baseURL {
            // Normalize the base URL path
            var path = baseURL.path
            
            // Remove trailing slash
            while path.hasSuffix("/") {
                path = String(path.dropLast())
            }
            
            // Check if path already ends with /v1
            if path.hasSuffix("/v1") {
                // Base URL already has /v1, just append /models
                return baseURL.appendingPathComponent("models")
            } else {
                // Need to add /v1/models
                return baseURL.appendingPathComponent("v1/models")
            }
        } else {
            // Default OpenAI URL
            return URL(string: "https://api.openai.com/v1/models")!
        }
    }
    
    // MARK: - Conversion Helpers
    
    private func convertMessage(_ message: LLMMessage) throws -> MessageParam {
        switch message.role {
        case .system:
            return .system(.init(content: .textContent(message.textContent)))
            
        case .user:
            // Check if we have images
            let hasImages = message.content.contains { content in
                switch content {
                case .imageBase64, .imageURL:
                    return true
                default:
                    return false
                }
            }
            
            if hasImages {
                // Use vision format with array of content parts
                var contentParts: [MessageParam.UserMessageParam.Content.ContentPart] = []
                
                for content in message.content {
                    switch content {
                    case .text(let text):
                        contentParts.append(.text(TextParam(text: text)))
                        
                    case .imageBase64(let data, let mimeType):
                        let imageURL = "data:\(mimeType);base64,\(data)"
                        contentParts.append(.image(ImageParam(
                            imageUrl: ImageParam.ImageURL(url: imageURL, detail: .auto)
                        )))
                        
                    case .imageURL(let url):
                        contentParts.append(.image(ImageParam(
                            imageUrl: ImageParam.ImageURL(url: url.absoluteString, detail: .auto)
                        )))
                        
                    case .toolResult:
                        // Tool results shouldn't be in user messages
                        break
                    }
                }
                
                return .user(.init(content: .contentParts(contentParts)))
            } else {
                return .user(.init(content: .string(message.textContent)))
            }
            
        case .assistant:
            if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                let openAIToolCalls = toolCalls.map { call in
                    ToolCallParam(
                        id: call.id,
                        function: ToolCallParam.FunctionCall(
                            arguments: call.function.arguments,
                            name: call.function.name
                        )
                    )
                }
                let textContent: MessageParam.TextOrRefusalContent? = 
                    message.textContent.isEmpty ? nil : .textContent(message.textContent)
                return .assistant(.init(content: textContent, toolCalls: openAIToolCalls))
            } else {
                return .assistant(.init(content: .textContent(message.textContent)))
            }
            
        case .tool:
            guard let toolCallId = message.toolCallId else {
                throw LLMError.invalidConfiguration(message: "Tool message missing toolCallId")
            }
            // Get the content from the tool result
            var resultContent = ""
            for content in message.content {
                if case .toolResult(_, let c) = content {
                    resultContent = c
                    break
                }
            }
            if resultContent.isEmpty {
                resultContent = message.textContent
            }
            return .tool(.init(content: .textContent(resultContent), toolCallId: toolCallId))
        }
    }
    
    private func convertTool(_ tool: LLMToolDefinition) -> ChatQuery.ChatCompletionToolParam? {
        guard tool.type == "function" else { return nil }
        
        // Convert parameters to JSONSchema format
        let parameters = convertParametersToSchema(tool.function.parameters)
        
        return ChatQuery.ChatCompletionToolParam(
            function: .init(
                name: tool.function.name,
                description: tool.function.description,
                parameters: parameters
            )
        )
    }
    
    private func convertParametersToSchema(_ parameters: [String: Any]) -> JSONSchema? {
        // Build the JSON Schema from the parameters dictionary
        var fields: [JSONSchemaField] = []
        
        // Type
        if let type = parameters["type"] as? String {
            if let instanceType = convertTypeString(type) {
                fields.append(.type(instanceType))
            }
        }
        
        // Properties
        if let properties = parameters["properties"] as? [String: Any] {
            var schemaProperties: [String: JSONSchema] = [:]
            for (key, value) in properties {
                if let propDict = value as? [String: Any] {
                    schemaProperties[key] = convertPropertyToSchema(propDict)
                }
            }
            fields.append(.properties(schemaProperties))
        }
        
        // Required
        if let required = parameters["required"] as? [String] {
            fields.append(.required(required))
        }
        
        // Additional properties
        if let additionalProperties = parameters["additionalProperties"] as? Bool {
            fields.append(.additionalProperties(.boolean(additionalProperties)))
        }
        
        guard !fields.isEmpty else { return nil }
        
        return JSONSchema(fields: fields)
    }
    
    private func convertTypeString(_ typeString: String) -> JSONSchemaInstanceType? {
        switch typeString {
        case "object": return .object
        case "string": return .string
        case "number": return .number
        case "integer": return .integer
        case "boolean": return .boolean
        case "array": return .array
        case "null": return .null
        default: return nil
        }
    }
    
    private func convertPropertyToSchema(_ property: [String: Any]) -> JSONSchema {
        var fields: [JSONSchemaField] = []
        
        if let type = property["type"] as? String,
           let instanceType = convertTypeString(type) {
            fields.append(.type(instanceType))
        }
        
        if let description = property["description"] as? String {
            fields.append(.description(description))
        }
        
        // Handle enum values - use anyOf with const values
        if let enumValues = property["enum"] as? [String] {
            let enumSchemas = enumValues.map { value in
                JSONSchema(fields: [.const(value)])
            }
            fields.append(.anyOf(enumSchemas))
        }
        
        // Handle array items
        if let items = property["items"] as? [String: Any] {
            fields.append(.items(convertPropertyToSchema(items)))
        }
        
        return JSONSchema(fields: fields)
    }
    
    private func convertResponse(_ result: ChatResult) throws -> LLMResponse {
        let choices = result.choices.map { choice -> LLMResponseChoice in
            // Convert tool calls if present
            var toolCalls: [LLMToolCall]? = nil
            if let openAIToolCalls = choice.message.toolCalls {
                toolCalls = openAIToolCalls.map { call in
                    LLMToolCall(
                        id: call.id,
                        type: "function",
                        function: LLMFunctionCall(
                            name: call.function.name,
                            arguments: call.function.arguments
                        )
                    )
                }
            }
            
            // Build the message
            let message = LLMMessage(
                role: .assistant,
                content: [.text(choice.message.content ?? "")],
                name: nil,
                toolCalls: toolCalls,
                toolCallId: nil
            )
            
            // Convert finish reason
            let finishReason: LLMFinishReason?
            let reason = choice.finishReason
            switch reason {
            case "stop":
                finishReason = .stop
            case "length":
                finishReason = .length
            case "tool_calls":
                finishReason = .toolCalls
            case "content_filter":
                finishReason = .contentFilter
            default:
                finishReason = .unknown
            }
            
            return LLMResponseChoice(
                index: choice.index,
                message: message,
                finishReason: finishReason
            )
        }
        
        // Convert usage
        var usage: LLMUsage? = nil
        if let openAIUsage = result.usage {
            usage = LLMUsage(
                promptTokens: openAIUsage.promptTokens,
                completionTokens: openAIUsage.completionTokens,
                totalTokens: openAIUsage.totalTokens
            )
        }
        
        return LLMResponse(
            id: result.id,
            model: result.model,
            created: Date(timeIntervalSince1970: TimeInterval(result.created)),
            choices: choices,
            usage: usage
        )
    }
    
    // MARK: - Raw HTTP Fallback (for providers with non-standard responses)
    
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
    
    private func buildChatURL() -> URL {
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
    
    private func convertMessageToDict(_ message: LLMMessage) throws -> [String: Any] {
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
    
    private func convertToolToDict(_ tool: LLMToolDefinition) -> [String: Any] {
        return [
            "type": "function",
            "function": [
                "name": tool.function.name,
                "description": tool.function.description,
                "parameters": tool.function.parameters
            ]
        ]
    }
    
    private func parseRawChatResponse(_ data: Data) throws -> LLMResponse {
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
