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
        tools: [LLMToolDefinition]?,
        temperature: Double?,
        maxTokens: Int?
    ) async throws -> LLMResponse {
        // Convert messages to OpenAI format
        let openAIMessages = try messages.map { try convertMessage($0) }
        
        // Convert tools to OpenAI format
        let openAITools = tools?.compactMap { convertTool($0) }
        
        // Build the query
        let query = ChatQuery(
            messages: openAIMessages,
            model: configuration.model,
            maxCompletionTokens: maxTokens,
            temperature: temperature,
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
            throw LLMError.decodingError(underlying: error)
        } catch {
            // Try to extract more info from the error
            let errorMessage = error.localizedDescription
            if errorMessage.contains("401") || errorMessage.contains("unauthorized") {
                throw LLMError.authenticationError(message: errorMessage)
            } else if errorMessage.contains("429") || errorMessage.contains("rate limit") {
                throw LLMError.rateLimitError(retryAfter: nil)
            }
            throw LLMError.unknown(message: errorMessage)
        }
    }
    
    public func testConnection() async throws -> Bool {
        // Send a simple message to test the connection
        let testMessages: [LLMMessage] = [
            .user("Hello")
        ]
        
        let _ = try await chat(messages: testMessages, tools: nil, temperature: nil, maxTokens: 5)
        return true
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
}
