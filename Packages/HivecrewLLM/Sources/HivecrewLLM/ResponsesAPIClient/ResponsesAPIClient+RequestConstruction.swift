import Foundation

extension ResponsesAPIClient {
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
        let repairedMessages = LLMConversationRepair
            .repairIncompleteToolCallHistory(messages)
            .messages
        let effectiveStream = responsesAPIRequiresStreamingTransport(
            backendMode: configuration.backendMode,
            requestedStream: stream
        )
        let systemTexts = repairedMessages
            .filter { $0.role == .system }
            .map(\.textContent)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let nonSystemMessages = repairedMessages.filter { $0.role != .system }

        var body: [String: Any] = [
            "model": configuration.model,
            "store": false,
            "stream": effectiveStream,
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

        if configuration.backendMode == .codexOAuth,
           let serviceTier = configuration.serviceTier {
            body["service_tier"] = serviceTier.rawValue
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

func responsesAPIRequiresStreamingTransport(
    backendMode: LLMBackendMode,
    requestedStream: Bool
) -> Bool {
    requestedStream || backendMode == .codexOAuth
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
    serviceTier: LLMServiceTier? = nil,
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
        reasoningEffort: reasoningEffort,
        serviceTier: serviceTier
    )
    let client = ResponsesAPIClient(configuration: configuration)
    return try client.buildRequestBody(messages: messages, tools: tools, stream: stream)
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
