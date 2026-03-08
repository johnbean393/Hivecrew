import Foundation

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

func parseModelsResponse(_ data: Data) throws -> [LLMProviderModel] {
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

func logStrictModelsDecodeFailure(error: Error, data: Data) {
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
        "context_length", "contextLength", "max_context_length", "max_input_tokens",
        "input_token_limit", "inputTokenLimit", "token_limit", "context_window"
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
        "supports_vision", "supportsVision", "vision", "supports_image_input",
        "supportsImageInput", "image_input", "imageInput", "supports_image_detail_original"
    ]) ?? firstBool(in: capabilities, keys: [
        "supports_vision", "supportsVision", "vision", "supports_image_input",
        "supportsImageInput", "image_input", "imageInput"
    ]) ?? inputModalities?.contains(where: { $0.caseInsensitiveCompare("image") == .orderedSame })

    let reasoningCapability: LLMReasoningCapability
    if let supportedReasoningLevels, !supportedReasoningLevels.isEmpty {
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
