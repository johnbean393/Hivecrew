import Foundation

/// Client for OpenAI Responses API-compatible providers.
public final class ResponsesAPIClient: LLMClientProtocol, @unchecked Sendable {
    public let configuration: LLMConfiguration

    private let urlSession: URLSession
    private let defaultCodexOAuthInstructions = "You are a helpful assistant."

    private var usesChatGPTOAuth: Bool {
        configuration.authMode == .chatGPTOAuth || configuration.backendMode == .codexOAuth
    }

    public init(configuration: LLMConfiguration) {
        self.configuration = configuration

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
        do {
            return try await sendChat(messages: messages, tools: tools, forceRefresh: false)
        } catch let error as LLMError {
            throw error
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

    public func chatWithStreaming(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        onReasoningUpdate: ReasoningStreamCallback?,
        onContentUpdate: ContentStreamCallback?
    ) async throws -> LLMResponse {
        do {
            return try await sendChatWithStreaming(
                messages: messages,
                tools: tools,
                onReasoningUpdate: onReasoningUpdate,
                onContentUpdate: onContentUpdate,
                forceRefresh: false
            )
        } catch let error as LLMError {
            throw error
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

    public func testConnection() async throws -> Bool {
        _ = try await listModelsDetailed()
        return true
    }

    public func listModels() async throws -> [String] {
        try await listModelsDetailed().map(\.id)
    }

    public func listModelsDetailed() async throws -> [LLMProviderModel] {
        do {
            return try await fetchModels(forceRefresh: false)
        } catch let error as LLMError {
            throw error
        } catch let error as URLError {
            if error.code == .timedOut {
                throw LLMError.timeout
            }
            if error.code == .cancelled {
                throw LLMError.cancelled
            }
            throw LLMError.networkError(underlying: error)
        } catch {
            throw LLMError.unknown(message: error.localizedDescription)
        }
    }
}

private final class ModelsDebugLoggingState: @unchecked Sendable {
    static let shared = ModelsDebugLoggingState()

    private let lock = NSLock()
    private var hasLoggedStrictDecodeFailure = false

    func shouldLogStrictDecodeFailure() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !hasLoggedStrictDecodeFailure else {
            return false
        }

        hasLoggedStrictDecodeFailure = true
        return true
    }
}

// MARK: - Internal Request Execution

private extension ResponsesAPIClient {
    func sendChat(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        forceRefresh: Bool
    ) async throws -> LLMResponse {
        let request = try await buildRequest(messages: messages, tools: tools, stream: false, forceRefresh: forceRefresh)
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.unknown(message: "Invalid response type")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "No response body"
            if (httpResponse.statusCode == 401 || httpResponse.statusCode == 403), usesChatGPTOAuth, !forceRefresh {
                return try await sendChat(messages: messages, tools: tools, forceRefresh: true)
            }
            throw classifyHTTPError(statusCode: httpResponse.statusCode, body: body)
        }

        return try parseNonStreamingResponse(data)
    }

    func sendChatWithStreaming(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        onReasoningUpdate: ReasoningStreamCallback?,
        onContentUpdate: ContentStreamCallback?,
        forceRefresh: Bool
    ) async throws -> LLMResponse {
        let request = try await buildRequest(messages: messages, tools: tools, stream: true, forceRefresh: forceRefresh)
        let (bytes, response) = try await urlSession.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.unknown(message: "Invalid response type")
        }

        guard httpResponse.statusCode == 200 else {
            var errorData = Data()
            for try await byte in bytes {
                errorData.append(byte)
            }
            let body = String(data: errorData, encoding: .utf8) ?? "No response body"
            if (httpResponse.statusCode == 401 || httpResponse.statusCode == 403), usesChatGPTOAuth, !forceRefresh {
                return try await sendChatWithStreaming(
                    messages: messages,
                    tools: tools,
                    onReasoningUpdate: onReasoningUpdate,
                    onContentUpdate: onContentUpdate,
                    forceRefresh: true
                )
            }
            throw classifyHTTPError(statusCode: httpResponse.statusCode, body: body)
        }

        return try await parseStreamingResponse(
            bytes: bytes,
            onReasoningUpdate: onReasoningUpdate,
            onContentUpdate: onContentUpdate
        )
    }

    func fetchModels(forceRefresh: Bool) async throws -> [LLMProviderModel] {
        let request = try await buildModelsRequest(forceRefresh: forceRefresh)
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.unknown(message: "Invalid response type")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "No response body"
            if (httpResponse.statusCode == 401 || httpResponse.statusCode == 403), usesChatGPTOAuth, !forceRefresh {
                return try await fetchModels(forceRefresh: true)
            }
            throw classifyHTTPError(statusCode: httpResponse.statusCode, body: body)
        }

        do {
            let decoded = try JSONDecoder().decode(StrictModelsResponse.self, from: data)
            return LLMProviderModel.sortByVersionDescending(
                decoded.data
                    .filter(\.isSupportedInAPI)
                    .map { model in
                        let supportedEfforts = model.supportedReasoningLevels?.map(\.effort) ?? []
                        let supportsReasoningToggle = model.supportedParameters?.contains(where: {
                            $0.caseInsensitiveCompare("reasoning") == .orderedSame
                        }) == true
                        let reasoningCapability: LLMReasoningCapability
                        if !supportedEfforts.isEmpty {
                            reasoningCapability = LLMReasoningCapability(
                                kind: .effort,
                                supportedEfforts: supportedEfforts,
                                defaultEffort: model.defaultReasoningLevel,
                                defaultEnabled: false
                            )
                        } else if supportsReasoningToggle {
                            reasoningCapability = LLMReasoningCapability(
                                kind: .toggle,
                                supportedEfforts: [],
                                defaultEffort: nil,
                                defaultEnabled: true
                            )
                        } else {
                            reasoningCapability = .none
                        }
                        return LLMProviderModel(
                            id: model.id,
                            name: model.name,
                            description: model.description,
                            contextLength: model.contextLength,
                            createdAt: model.created.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                            inputModalities: model.inputModalities,
                            outputModalities: model.outputModalities,
                            supportsVisionInput: model.supportsVision,
                            reasoningCapability: reasoningCapability
                        )
                    }
                    .map { normalizeProviderModelMetadata($0, backendMode: configuration.backendMode) }
            )
        } catch {
            logStrictModelsDecodeFailure(error: error, data: data)
            return LLMProviderModel.sortByVersionDescending(
                try parseModelsResponse(data)
                    .map { normalizeProviderModelMetadata($0, backendMode: configuration.backendMode) }
            )
        }
    }
}

// MARK: - Request Construction

private extension ResponsesAPIClient {
    func buildRequest(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        stream: Bool,
        forceRefresh: Bool
    ) async throws -> URLRequest {
        let endpoint = buildResponsesURL()

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(try await resolveAuthorizationHeader(forceRefresh: forceRefresh), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let orgId = configuration.organizationId, !usesChatGPTOAuth {
            request.setValue(orgId, forHTTPHeaderField: "OpenAI-Organization")
        }
        request.timeoutInterval = configuration.timeoutInterval

        let body = try buildRequestBody(messages: messages, tools: tools, stream: stream)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        return request
    }

    func buildModelsRequest(forceRefresh: Bool) async throws -> URLRequest {
        var request = URLRequest(url: buildModelsURL())
        request.httpMethod = "GET"
        request.setValue(try await resolveAuthorizationHeader(forceRefresh: forceRefresh), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let orgId = configuration.organizationId, !usesChatGPTOAuth {
            request.setValue(orgId, forHTTPHeaderField: "OpenAI-Organization")
        }
        request.timeoutInterval = configuration.timeoutInterval
        return request
    }

    func resolveAuthorizationHeader(forceRefresh: Bool) async throws -> String {
        if usesChatGPTOAuth {
            let accessToken = try await resolveOAuthAccessToken(forceRefresh: forceRefresh)
            return "Bearer \(accessToken)"
        }

        guard !configuration.apiKey.isEmpty else {
            throw LLMError.authenticationError(message: "Missing API key")
        }
        return "Bearer \(configuration.apiKey)"
    }

    func resolveOAuthAccessToken(forceRefresh: Bool) async throws -> String {
        guard var tokens = CodexOAuthTokenStore.retrieve(providerId: configuration.id) else {
            throw LLMError.authenticationError(message: "ChatGPT OAuth is not connected for this provider")
        }

        if forceRefresh || tokens.shouldRefresh(within: 120) {
            tokens = try await refreshOAuthTokens(tokens)
            guard CodexOAuthTokenStore.store(providerId: configuration.id, tokens: tokens) else {
                throw LLMError.authenticationError(message: "Failed to persist refreshed ChatGPT OAuth tokens")
            }
        }

        return tokens.accessToken
    }

    func refreshOAuthTokens(_ current: CodexOAuthTokens) async throws -> CodexOAuthTokens {
        var request = URLRequest(url: codexOAuthTokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = configuration.timeoutInterval

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: current.refreshToken),
            URLQueryItem(name: "client_id", value: codexOAuthClientID)
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.authenticationError(message: "Invalid token refresh response")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "No response body"
            throw classifyHTTPError(statusCode: httpResponse.statusCode, body: body)
        }

        let decoded = try JSONDecoder().decode(OAuthRefreshResponse.self, from: data)
        let expiresIn = decoded.expiresIn ?? 3600

        return CodexOAuthTokens(
            accessToken: decoded.accessToken,
            refreshToken: decoded.refreshToken ?? current.refreshToken,
            idToken: decoded.idToken ?? current.idToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn))
        )
    }

    func buildRequestBody(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        stream: Bool
    ) throws -> [String: Any] {
        let systemTexts = messages
            .filter { $0.role == .system }
            .map(\.textContent)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let nonSystemMessages = messages.filter { $0.role != .system }

        var body: [String: Any] = [
            "model": configuration.model,
            "store": false,
            "stream": stream,
            "input": try nonSystemMessages.flatMap { try convertMessageToInputItems($0) }
        ]

        if !systemTexts.isEmpty {
            body["instructions"] = systemTexts.joined(separator: "\n\n")
        } else if configuration.backendMode == .codexOAuth {
            body["instructions"] = defaultCodexOAuthInstructions
        }

        if let tools, !tools.isEmpty {
            body["tools"] = tools.map { tool in
                [
                    "type": "function",
                    "name": tool.function.name,
                    "description": tool.function.description,
                    "parameters": tool.function.parameters
                ] as [String: Any]
            }
            body["tool_choice"] = "auto"
        }

        if let reasoningEffort = configuration.reasoningEffort?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !reasoningEffort.isEmpty {
            body["reasoning"] = ["effort": reasoningEffort]
        } else if configuration.reasoningEnabled == true {
            body["reasoning"] = ["enabled": true]
        }

        return body
    }

    func convertMessageToInputItems(_ message: LLMMessage) throws -> [[String: Any]] {
        switch message.role {
        case .system:
            return []
        case .user:
            var items: [[String: Any]] = []
            let content = convertMessageContentToInputContent(message.content, role: .user)
            if !content.isEmpty {
                items.append([
                    "type": "message",
                    "role": "user",
                    "content": content
                ])
            }

            return items
        case .assistant:
            var items: [[String: Any]] = []
            let content = convertMessageContentToInputContent(message.content, role: .assistant)
            if !content.isEmpty {
                items.append([
                    "type": "message",
                    "role": "assistant",
                    "content": content
                ])
            }

            // Keep tool call history in replayed context.
            if let toolCalls = message.toolCalls {
                for toolCall in toolCalls {
                    items.append([
                        "type": "function_call",
                        "call_id": toolCall.id,
                        "name": toolCall.function.name,
                        "arguments": toolCall.function.arguments
                    ])
                }
            }

            return items
        case .tool:
            guard let toolCallId = message.toolCallId else {
                throw LLMError.invalidConfiguration(message: "Tool message missing toolCallId")
            }
            let output = extractToolOutput(from: message)
            return [[
                "type": "function_call_output",
                "call_id": toolCallId,
                "output": output
            ]]
        }
    }

    func convertMessageContentToInputContent(
        _ content: [LLMMessageContent],
        role: LLMMessageRole
    ) -> [[String: Any]] {
        content.compactMap { part in
            switch part {
            case .text(let text):
                let contentType = role == .assistant ? "output_text" : "input_text"
                return ["type": contentType, "text": text]
            case .imageBase64(let data, let mimeType):
                guard role == .user else { return nil }
                return [
                    "type": "input_image",
                    "image_url": "data:\(mimeType);base64,\(data)"
                ]
            case .imageURL(let url):
                guard role == .user else { return nil }
                return ["type": "input_image", "image_url": url.absoluteString]
            case .toolResult:
                return nil
            }
        }
    }

    func extractToolOutput(from message: LLMMessage) -> String {
        let toolOutputs = message.content.compactMap { part -> String? in
            guard case let .toolResult(_, content) = part else { return nil }
            return content
        }

        if !toolOutputs.isEmpty {
            return toolOutputs.joined(separator: "\n")
        }

        return message.textContent
    }

    func buildResponsesURL() -> URL {
        if configuration.backendMode == .codexOAuth {
            return buildCodexOAuthURL(pathComponent: "responses")
        }
        return resolvedBaseURL().appendingPathComponent("responses")
    }

    func buildModelsURL() -> URL {
        if configuration.backendMode == .codexOAuth {
            return buildCodexOAuthURL(pathComponent: "models")
        }
        return resolvedBaseURL().appendingPathComponent("models")
    }

    func resolvedBaseURL() -> URL {
        if configuration.backendMode == .codexOAuth {
            return codexOAuthBaseURL
        }
        return configuration.baseURL ?? defaultLLMProviderBaseURL
    }
}

func buildCodexOAuthRequestBodyForTests(
    model: String,
    messages: [LLMMessage],
    tools: [LLMToolDefinition]?,
    stream: Bool
) throws -> [String: Any] {
    let configuration = LLMConfiguration(
        id: "codex-oauth-test",
        displayName: "Codex OAuth Test",
        baseURL: codexOAuthBaseURL,
        apiKey: "",
        model: model,
        organizationId: nil,
        backendMode: .codexOAuth,
        authMode: .chatGPTOAuth
    )
    let client = ResponsesAPIClient(configuration: configuration)
    return try client.buildRequestBody(messages: messages, tools: tools, stream: stream)
}

func buildResponsesRequestBodyForTests(
    model: String,
    backendMode: LLMBackendMode = .responses,
    authMode: LLMAuthMode = .apiKey,
    reasoningEnabled: Bool? = nil,
    reasoningEffort: String? = nil,
    messages: [LLMMessage],
    tools: [LLMToolDefinition]?,
    stream: Bool
) throws -> [String: Any] {
    let configuration = LLMConfiguration(
        id: "responses-test",
        displayName: "Responses Test",
        baseURL: URL(string: "https://example.com/v1"),
        apiKey: "test-key",
        model: model,
        organizationId: nil,
        backendMode: backendMode,
        authMode: authMode,
        reasoningEnabled: reasoningEnabled,
        reasoningEffort: reasoningEffort
    )
    let client = ResponsesAPIClient(configuration: configuration)
    return try client.buildRequestBody(messages: messages, tools: tools, stream: stream)
}

func parseResponsesModelsForTests(
    _ data: Data,
    backendMode: LLMBackendMode = .responses
) throws -> [LLMProviderModel] {
    let configuration = LLMConfiguration(
        id: "responses-models-test",
        displayName: "Responses Models Test",
        baseURL: URL(string: "https://example.com/v1"),
        apiKey: "test-key",
        model: "test-model",
        organizationId: nil,
        backendMode: backendMode,
        authMode: backendMode == .codexOAuth ? .chatGPTOAuth : .apiKey
    )

    do {
        let decoded = try JSONDecoder().decode(StrictModelsResponse.self, from: data)
        return decoded.data
            .filter(\.isSupportedInAPI)
            .map { model in
                let supportedEfforts = model.supportedReasoningLevels?.map(\.effort) ?? []
                let supportsReasoningToggle = model.supportedParameters?.contains(where: {
                    $0.caseInsensitiveCompare("reasoning") == .orderedSame
                }) == true
                let reasoningCapability: LLMReasoningCapability
                if !supportedEfforts.isEmpty {
                    reasoningCapability = LLMReasoningCapability(
                        kind: .effort,
                        supportedEfforts: supportedEfforts,
                        defaultEffort: model.defaultReasoningLevel,
                        defaultEnabled: false
                    )
                } else if supportsReasoningToggle {
                    reasoningCapability = LLMReasoningCapability(
                        kind: .toggle,
                        supportedEfforts: [],
                        defaultEffort: nil,
                        defaultEnabled: true
                    )
                } else {
                    reasoningCapability = .none
                }
                return LLMProviderModel(
                    id: model.id,
                    name: model.name,
                    description: model.description,
                    contextLength: model.contextLength,
                    createdAt: model.created.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                    inputModalities: model.inputModalities,
                    outputModalities: model.outputModalities,
                    supportsVisionInput: model.supportsVision,
                    reasoningCapability: reasoningCapability
                )
            }
            .map { normalizeProviderModelMetadata($0, backendMode: configuration.backendMode) }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    } catch {
        return try parseModelsResponse(data)
            .map { normalizeProviderModelMetadata($0, backendMode: configuration.backendMode) }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }
}

func normalizeProviderModelMetadata(
    _ model: LLMProviderModel,
    backendMode: LLMBackendMode
) -> LLMProviderModel {
    guard backendMode == .codexOAuth else {
        return model
    }

    return LLMProviderModel(
        id: model.id,
        name: model.name,
        description: model.description,
        contextLength: model.contextLength,
        createdAt: model.createdAt,
        inputModalities: mergeModalities(model.inputModalities, ["text", "image"]),
        outputModalities: model.outputModalities,
        supportsVisionInput: true,
        reasoningCapability: model.reasoningCapability
    )
}

private struct OAuthRefreshResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case expiresIn = "expires_in"
    }
}

// MARK: - Parsing

private extension ResponsesAPIClient {
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
        var usage: LLMUsage? = nil
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
                    case "response.reasoning_text.delta", "response.reasoning.delta":
                        let delta = event["delta"] as? String ?? ""
                        if !delta.isEmpty {
                            accumulatedReasoning += delta
                            onReasoningUpdate?(accumulatedReasoning)
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
                            let final = parseFinalResponseEnvelope(response)
                            return final
                        }
                    case "response.failed":
                        let message = (event["error"] as? [String: Any])?["message"] as? String ?? "Response failed"
                        throw LLMError.unknown(message: message)
                    default:
                        // Also support providers that stream as incremental response envelopes.
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

        // Provider compatibility: some APIs include a convenience `output_text` field.
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

    func parseUsage(_ usageDict: [String: Any]?) -> LLMUsage? {
        guard let usageDict else { return nil }

        let promptTokens =
            (usageDict["prompt_tokens"] as? Int)
            ?? (usageDict["input_tokens"] as? Int)
            ?? 0

        let completionTokens =
            (usageDict["completion_tokens"] as? Int)
            ?? (usageDict["output_tokens"] as? Int)
            ?? 0

        let totalTokens =
            (usageDict["total_tokens"] as? Int)
            ?? (promptTokens + completionTokens)

        return LLMUsage(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: totalTokens
        )
    }
}

// MARK: - Error Mapping

private extension ResponsesAPIClient {
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

        if normalized.contains("oversized payload") ||
            normalized.contains("payload too large") ||
            normalized.contains("request entity too large") {
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

// MARK: - Model Listing Response

private func parseModelsResponse(_ data: Data) throws -> [LLMProviderModel] {
    let json = try JSONSerialization.jsonObject(with: data)
    let modelPayloads = extractModelPayloads(from: json)

    if modelPayloads.isEmpty {
        throw LLMError.decodingError(
            underlying: NSError(
                domain: "HivecrewLLM.Responses",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Models response did not contain any parseable model entries"]
            )
        )
    }

    let models = modelPayloads.compactMap(parseModelPayload)
    if !models.isEmpty {
        return models
    }

    throw LLMError.decodingError(
        underlying: NSError(
            domain: "HivecrewLLM.Responses",
            code: -3,
            userInfo: [NSLocalizedDescriptionKey: "Models response entries were present but none could be normalized"]
        )
    )
}

private func logStrictModelsDecodeFailure(error: Error, data: Data) {
    guard ModelsDebugLoggingState.shared.shouldLogStrictDecodeFailure() else {
        return
    }

    let rawBody = String(data: data, encoding: .utf8) ?? "<non-utf8 response body>"
    let maxLoggedCharacters = 1200
    let truncatedBody: String
    if rawBody.count > maxLoggedCharacters {
        let endIndex = rawBody.index(rawBody.startIndex, offsetBy: maxLoggedCharacters)
        truncatedBody = String(rawBody[..<endIndex]) + "\n...[truncated \(rawBody.count - maxLoggedCharacters) chars]"
    } else {
        truncatedBody = rawBody
    }
    let message = """
    [HivecrewLLM] Strict /models decode failed: \(error)
    [HivecrewLLM] Raw /models response:
    \(truncatedBody)

    """

    if let encoded = message.data(using: .utf8) {
        FileHandle.standardError.write(encoded)
    } else {
        print(message)
    }
}

private func extractModelPayloads(from json: Any) -> [[String: Any]] {
    if let array = json as? [[String: Any]] {
        return array
    }

    if let stringArray = json as? [String] {
        return stringArray.map { ["id": $0] }
    }

    guard let dictionary = json as? [String: Any] else {
        return []
    }

    if looksLikeModelPayload(dictionary) {
        return [dictionary]
    }

    for key in ["data", "models", "items", "results"] {
        if let nested = dictionary[key] {
            let extracted = extractModelPayloads(from: nested)
            if !extracted.isEmpty {
                return extracted
            }

            let keyed = extractKeyedModelPayloads(from: nested)
            if !keyed.isEmpty {
                return keyed
            }
        }
    }

    return extractKeyedModelPayloads(from: dictionary)
}

private func extractKeyedModelPayloads(from value: Any) -> [[String: Any]] {
    guard let dictionary = value as? [String: Any] else {
        return []
    }

    var payloads: [[String: Any]] = []
    for (key, value) in dictionary {
        if let modelDict = value as? [String: Any] {
            var enriched = modelDict
            if enriched["id"] == nil {
                enriched["id"] = key
            }
            if looksLikeModelPayload(enriched) {
                payloads.append(enriched)
            }
        } else if let modelID = value as? String, key == "id" || key == "model" || key == "name" {
            payloads.append(["id": modelID])
        }
    }

    return payloads
}

private func looksLikeModelPayload(_ payload: [String: Any]) -> Bool {
    payload["id"] is String
        || payload["slug"] is String
        || payload["name"] is String
        || payload["display_name"] is String
        || payload["model"] is String
}

private func parseModelPayload(_ payload: [String: Any]) -> LLMProviderModel? {
    if firstBool(in: payload, keys: ["supported_in_api", "supportedInAPI"]) == false {
        return nil
    }

    let id = firstString(in: payload, keys: ["id", "slug", "model", "name"])
    guard let id, !id.isEmpty else {
        return nil
    }

    let name = firstString(in: payload, keys: ["name", "label", "display_name", "displayName"])
    let description = firstString(in: payload, keys: ["description"])
    let created = firstInt(in: payload, keys: ["created"]).map { Date(timeIntervalSince1970: TimeInterval($0)) }
    let contextLength = firstInt(in: payload, keys: [
        "context_length",
        "contextLength",
        "max_context_length",
        "max_input_tokens",
        "input_token_limit",
        "inputTokenLimit",
        "token_limit",
        "context_window"
    ])

    let architecture = payload["architecture"] as? [String: Any]
    let modalities = payload["modalities"] as? [String: Any]
    let capabilities = payload["capabilities"] as? [String: Any]
    let supportedReasoningLevels = payload["supported_reasoning_levels"] as? [[String: Any]]

    let inputModalities = mergeModalities(
        firstStringArray(in: architecture, keys: ["input_modalities", "inputModalities"]),
        firstStringArray(in: payload, keys: ["input_modalities", "inputModalities"]),
        firstStringArray(in: modalities, keys: ["input", "inputs", "input_modalities", "inputModalities"])
    )
    let outputModalities = mergeModalities(
        firstStringArray(in: architecture, keys: ["output_modalities", "outputModalities"]),
        firstStringArray(in: payload, keys: ["output_modalities", "outputModalities"]),
        firstStringArray(in: modalities, keys: ["output", "outputs", "output_modalities", "outputModalities"])
    )

    let supportsVision = firstBool(in: payload, keys: [
        "supports_vision",
        "supportsVision",
        "vision",
        "supports_image_input",
        "supportsImageInput",
        "image_input",
        "imageInput",
        "supports_image_detail_original"
    ]) ?? firstBool(in: capabilities, keys: [
        "supports_vision",
        "supportsVision",
        "vision",
        "supports_image_input",
        "supportsImageInput",
        "image_input",
        "imageInput"
    ]) ?? inputModalities?.contains(where: { $0.caseInsensitiveCompare("image") == .orderedSame })

    let reasoningCapability: LLMReasoningCapability
    if let supportedReasoningLevels,
       !supportedReasoningLevels.isEmpty {
        let efforts = supportedReasoningLevels.compactMap { level in
            firstString(in: level, keys: ["effort"])
        }
        let defaultEffort = firstString(in: payload, keys: ["default_reasoning_level", "defaultReasoningLevel"])
        reasoningCapability = LLMReasoningCapability(
            kind: efforts.isEmpty ? .none : .effort,
            supportedEfforts: efforts,
            defaultEffort: defaultEffort,
            defaultEnabled: false
        )
    } else if let supportedParameters = firstStringArray(in: payload, keys: ["supported_parameters", "supportedParameters"]),
              supportedParameters.contains(where: { $0.caseInsensitiveCompare("reasoning") == .orderedSame }) {
        reasoningCapability = LLMReasoningCapability(
            kind: .toggle,
            supportedEfforts: [],
            defaultEffort: nil,
            defaultEnabled: true
        )
    } else {
        reasoningCapability = .none
    }

    return LLMProviderModel(
        id: id,
        name: name,
        description: description,
        contextLength: contextLength,
        createdAt: created,
        inputModalities: inputModalities,
        outputModalities: outputModalities,
        supportsVisionInput: supportsVision,
        reasoningCapability: reasoningCapability
    )
}

private func firstString(in dictionary: [String: Any]?, keys: [String]) -> String? {
    guard let dictionary else { return nil }
    for key in keys {
        if let value = dictionary[key] as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
    }
    return nil
}

private func firstInt(in dictionary: [String: Any]?, keys: [String]) -> Int? {
    guard let dictionary else { return nil }
    for key in keys {
        if let value = dictionary[key] as? Int {
            return value
        }
        if let value = dictionary[key] as? Double {
            return Int(value)
        }
        if let value = dictionary[key] as? String {
            let normalized = value.replacingOccurrences(of: ",", with: "")
            if let parsed = Int(normalized) {
                return parsed
            }
        }
    }
    return nil
}

private func firstBool(in dictionary: [String: Any]?, keys: [String]) -> Bool? {
    guard let dictionary else { return nil }
    for key in keys {
        if let value = dictionary[key] as? Bool {
            return value
        }
        if let value = dictionary[key] as? String {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes":
                return true
            case "false", "0", "no":
                return false
            default:
                continue
            }
        }
    }
    return nil
}

private func firstStringArray(in dictionary: [String: Any]?, keys: [String]) -> [String]? {
    guard let dictionary else { return nil }
    for key in keys {
        if let values = dictionary[key] as? [String] {
            return values
        }
        if let value = dictionary[key] as? String {
            return [value]
        }
    }
    return nil
}

private func mergeModalities(_ sources: [String]?...) -> [String]? {
    var merged: [String] = []
    var seen = Set<String>()

    for source in sources {
        guard let source else { continue }
        for value in source {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                merged.append(trimmed)
            }
        }
    }

    return merged.isEmpty ? nil : merged
}

private struct StrictModelsResponse: Decodable {
    let data: [ModelInfo]

    private enum CodingKeys: String, CodingKey {
        case data
        case models
        case items
        case results
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let models = try? container.decode([ModelInfo].self, forKey: .data) {
            data = models
            return
        }
        if let models = try? container.decode([ModelInfo].self, forKey: .models) {
            data = models
            return
        }
        if let models = try? container.decode([ModelInfo].self, forKey: .items) {
            data = models
            return
        }
        if let models = try? container.decode([ModelInfo].self, forKey: .results) {
            data = models
            return
        }

        throw DecodingError.keyNotFound(
            CodingKeys.data,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected one of data/models/items/results in /models response"
            )
        )
    }

    struct ModelInfo: Decodable {
        let id: String
        let name: String?
        let description: String?
        let created: Int?
        let contextLength: Int?
        let inputModalities: [String]?
        let outputModalities: [String]?
        let supportsVision: Bool?
        let supportedReasoningLevels: [ReasoningLevel]?
        let supportedParameters: [String]?
        let defaultReasoningLevel: String?
        let isSupportedInAPI: Bool

        struct ReasoningLevel: Decodable {
            let effort: String
        }

        enum CodingKeys: String, CodingKey {
            case id
            case slug
            case model
            case name
            case displayName = "display_name"
            case description
            case created
            case contextLength = "context_length"
            case contextLengthCamel = "contextLength"
            case maxContextLength = "max_context_length"
            case inputTokenLimit = "input_token_limit"
            case tokenLimit = "token_limit"
            case contextWindow = "context_window"
            case inputModalities = "input_modalities"
            case inputModalitiesCamel = "inputModalities"
            case outputModalities = "output_modalities"
            case outputModalitiesCamel = "outputModalities"
            case vision = "vision"
            case supportsVision = "supports_vision"
            case supportsVisionCamel = "supportsVision"
            case supportsImageDetailOriginal = "supports_image_detail_original"
            case supportedReasoningLevels = "supported_reasoning_levels"
            case supportedParameters = "supported_parameters"
            case supportedParametersCamel = "supportedParameters"
            case defaultReasoningLevel = "default_reasoning_level"
            case supportedInAPI = "supported_in_api"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let decodedID = try? container.decode(String.self, forKey: .id) {
                id = decodedID
            } else if let decodedSlug = try? container.decode(String.self, forKey: .slug) {
                id = decodedSlug
            } else if let decodedModel = try? container.decode(String.self, forKey: .model) {
                id = decodedModel
            } else {
                throw DecodingError.keyNotFound(
                    CodingKeys.id,
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Expected id, slug, or model in /models entry"
                    )
                )
            }

            name =
                (try? container.decodeIfPresent(String.self, forKey: .name))
                ?? (try? container.decodeIfPresent(String.self, forKey: .displayName))
            description = try? container.decodeIfPresent(String.self, forKey: .description)
            created = try? container.decodeIfPresent(Int.self, forKey: .created)

            contextLength = Self.decodeInt(from: container, keys: [
                .contextLength,
                .contextLengthCamel,
                .maxContextLength,
                .inputTokenLimit,
                .tokenLimit,
                .contextWindow
            ])

            inputModalities = Self.decodeStringArray(
                from: container,
                snakeCaseKey: .inputModalities,
                camelCaseKey: .inputModalitiesCamel
            )
            outputModalities = Self.decodeStringArray(
                from: container,
                snakeCaseKey: .outputModalities,
                camelCaseKey: .outputModalitiesCamel
            )

            supportsVision = Self.decodeBool(
                from: container,
                keys: [.supportsVision, .supportsVisionCamel, .vision, .supportsImageDetailOriginal]
            ) ?? inputModalities?.contains(where: { $0.caseInsensitiveCompare("image") == .orderedSame })

            supportedReasoningLevels = try? container.decodeIfPresent([ReasoningLevel].self, forKey: .supportedReasoningLevels)
            supportedParameters = Self.decodeStringArray(
                from: container,
                snakeCaseKey: .supportedParameters,
                camelCaseKey: .supportedParametersCamel
            )
            defaultReasoningLevel = try? container.decodeIfPresent(String.self, forKey: .defaultReasoningLevel)
            isSupportedInAPI = (try? container.decodeIfPresent(Bool.self, forKey: .supportedInAPI)) ?? true
        }

        private static func decodeInt(
            from container: KeyedDecodingContainer<CodingKeys>,
            keys: [CodingKeys]
        ) -> Int? {
            for key in keys {
                if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                    return value
                }
                if let value = try? container.decodeIfPresent(String.self, forKey: key) {
                    let normalized = value.replacingOccurrences(of: ",", with: "")
                    if let parsed = Int(normalized) {
                        return parsed
                    }
                }
            }
            return nil
        }

        private static func decodeBool(
            from container: KeyedDecodingContainer<CodingKeys>,
            keys: [CodingKeys]
        ) -> Bool? {
            for key in keys {
                if let value = try? container.decodeIfPresent(Bool.self, forKey: key) {
                    return value
                }
            }
            return nil
        }

        private static func decodeStringArray(
            from container: KeyedDecodingContainer<CodingKeys>,
            snakeCaseKey: CodingKeys,
            camelCaseKey: CodingKeys
        ) -> [String]? {
            if let values = try? container.decodeIfPresent([String].self, forKey: snakeCaseKey) {
                return values
            }
            if let values = try? container.decodeIfPresent([String].self, forKey: camelCaseKey) {
                return values
            }
            if let value = try? container.decodeIfPresent(String.self, forKey: snakeCaseKey) {
                return [value]
            }
            if let value = try? container.decodeIfPresent(String.self, forKey: camelCaseKey) {
                return [value]
            }
            return nil
        }
    }
}
