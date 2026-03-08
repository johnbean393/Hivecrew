//
//  OpenAICompatibleClient.swift
//  HivecrewLLM
//
//  OpenAI-compatible LLM client implementation using MacPaw's OpenAI library
//

import Foundation
import OpenAI

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
    let urlSession: URLSession
    
    public init(configuration: LLMConfiguration) {
        self.configuration = configuration
        
        // Build OpenAI configuration
        var openAIConfig: OpenAI.Configuration
        
        if let baseURL = configuration.baseURL {
            // Custom endpoint configuration
            openAIConfig = OpenAI.Configuration(
                token: configuration.apiKey,
                organizationIdentifier: configuration.organizationId,
                host: baseURL.host ?? defaultLLMProviderBaseURL.host!,
                port: baseURL.port ?? 443,
                scheme: baseURL.scheme ?? "https",
                timeoutInterval: configuration.timeoutInterval
            )
        } else {
            // Default OpenRouter configuration
            openAIConfig = OpenAI.Configuration(
                token: configuration.apiKey,
                organizationIdentifier: configuration.organizationId,
                timeoutInterval: configuration.timeoutInterval
            )
        }
        
        self.openAI = OpenAI(configuration: openAIConfig)

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = configuration.timeoutInterval
        sessionConfiguration.timeoutIntervalForResource = configuration.timeoutInterval
        sessionConfiguration.waitsForConnectivity = false
        self.urlSession = URLSession(configuration: sessionConfiguration)
    }
    
    public func chat(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?
    ) async throws -> LLMResponse {
        // Use raw HTTP for OpenRouter to enable reasoning tokens and handle provider quirks
        if configuration.isOpenRouter {
            return try await chatRaw(messages: messages, tools: tools)
        }
        
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
            if errorMessage.lowercased().contains("oversized payload") ||
                errorMessage.lowercased().contains("payload too large") ||
                errorMessage.lowercased().contains("request entity too large") {
                throw LLMError.payloadTooLarge(message: errorMessage)
            }
            if let contextInfo = ContextLimitErrorParser.parse(message: errorMessage) {
                throw LLMError.contextLimitExceeded(
                    message: errorMessage,
                    maxInputTokens: contextInfo.maxInputTokens,
                    requestedTokens: contextInfo.requestedTokens
                )
            }
            throw LLMError.unknown(message: errorMessage)
        }
    }
    
    public func chatWithStreaming(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        onReasoningUpdate: ReasoningStreamCallback?,
        onContentUpdate: ContentStreamCallback?
    ) async throws -> LLMResponse {
        // Use streaming raw HTTP to stream tokens
        return try await chatRawStreaming(
            messages: messages,
            tools: tools,
            onReasoningUpdate: onReasoningUpdate,
            onContentUpdate: onContentUpdate
        )
    }
    
    public func chatWithReasoningStream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        onReasoningUpdate: ReasoningStreamCallback?
    ) async throws -> LLMResponse {
        // Use the new streaming method
        return try await chatWithStreaming(
            messages: messages,
            tools: tools,
            onReasoningUpdate: onReasoningUpdate,
            onContentUpdate: nil
        )
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
        let models = try await listModelsDetailed()
        return models.map(\.id)
    }
    
    public func listModelsDetailed() async throws -> [LLMProviderModel] {
        let modelsResponse = try await fetchModelsResponse()
        
        return LLMProviderModel.sortByVersionDescending(
            modelsResponse.data.map { model in
                LLMProviderModel(
                    id: model.id,
                    name: model.name,
                    description: model.description,
                    contextLength: model.contextLength ?? model.topProvider?.contextLength,
                    createdAt: model.created.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                    inputModalities: model.normalizedInputModalities,
                    outputModalities: model.normalizedOutputModalities,
                    supportsVisionInput: model.normalizedSupportsVisionInput,
                    reasoningCapability: model.normalizedReasoningCapability
                )
            }
        )
    }
    
    private func fetchModelsResponse() async throws -> ModelsResponse {
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
            let (data, response) = try await urlSession.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw LLMError.unknown(message: "Invalid response type")
            }
            
            guard httpResponse.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? "No response body"
                throw LLMError.unknown(message: "HTTP \(httpResponse.statusCode): \(body)")
            }
            
            // Parse the response
            return try JSONDecoder().decode(ModelsResponse.self, from: data)
        } catch let error as LLMError {
            throw error
        } catch let error as URLError {
            if error.code == .timedOut {
                throw LLMError.timeout
            } else if error.code == .cancelled {
                throw LLMError.cancelled
            }
            throw LLMError.networkError(underlying: error)
        } catch {
            throw LLMError.unknown(message: error.localizedDescription)
        }
    }
    
    /// Build the models endpoint URL
    private func buildModelsURL() -> URL {
        if let baseURL = configuration.baseURL {
            return baseURL.appendingPathComponent("models")
        } else {
            return defaultLLMProviderBaseURL.appendingPathComponent("models")
        }
    }
}

func decodeOpenAICompatibleModelsForTests(from data: Data) throws -> [LLMProviderModel] {
    let modelsResponse = try JSONDecoder().decode(ModelsResponse.self, from: data)
    return modelsResponse.data
        .map { model in
            LLMProviderModel(
                id: model.id,
                name: model.name,
                description: model.description,
                contextLength: model.contextLength ?? model.topProvider?.contextLength,
                createdAt: model.created.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                inputModalities: model.normalizedInputModalities,
                outputModalities: model.normalizedOutputModalities,
                supportsVisionInput: model.normalizedSupportsVisionInput,
                reasoningCapability: model.normalizedReasoningCapability
            )
        }
        .sorted {
            $0.id.localizedStandardCompare($1.id) == .orderedAscending
        }
}
