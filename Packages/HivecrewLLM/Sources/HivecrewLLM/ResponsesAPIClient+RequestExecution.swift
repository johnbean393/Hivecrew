import Foundation

extension ResponsesAPIClient {
    func sendChat(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        forceRefresh: Bool
    ) async throws -> LLMResponse {
        if responsesAPIRequiresStreamingTransport(
            backendMode: configuration.backendMode,
            requestedStream: false
        ) {
            return try await sendChatWithStreaming(
                messages: messages,
                tools: tools,
                onReasoningUpdate: nil,
                onContentUpdate: nil,
                forceRefresh: forceRefresh
            )
        }

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
