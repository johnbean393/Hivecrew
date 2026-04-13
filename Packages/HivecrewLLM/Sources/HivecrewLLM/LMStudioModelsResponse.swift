import Foundation

struct LMStudioModelsResponse: Decodable {
    let models: [ModelInfo]

    struct ModelInfo: Decodable {
        let type: String
        let publisher: String?
        let key: String
        let displayName: String?
        let architecture: String?
        let quantization: Quantization?
        let sizeBytes: Int?
        let paramsString: String?
        let loadedInstances: [LoadedInstance]
        let maxContextLength: Int?
        let format: String?
        let capabilities: Capabilities?
        let description: String?

        enum CodingKeys: String, CodingKey {
            case type
            case publisher
            case key
            case displayName = "display_name"
            case architecture
            case quantization
            case sizeBytes = "size_bytes"
            case paramsString = "params_string"
            case loadedInstances = "loaded_instances"
            case maxContextLength = "max_context_length"
            case format
            case capabilities
            case description
        }

        struct Quantization: Decodable {
            let name: String?
            let bitsPerWeight: Double?

            enum CodingKeys: String, CodingKey {
                case name
                case bitsPerWeight = "bits_per_weight"
            }
        }

        struct LoadedInstance: Decodable {
            let id: String
            let config: Config

            struct Config: Decodable {
                let contextLength: Int?
                let maxContextLength: Int?

                enum CodingKeys: String, CodingKey {
                    case contextLength = "context_length"
                    case maxContextLength = "max_context_length"
                }
            }
        }

        struct Capabilities: Decodable {
            let vision: Bool?
            let trainedForToolUse: Bool?
            let reasoning: Reasoning?

            enum CodingKeys: String, CodingKey {
                case vision
                case trainedForToolUse = "trained_for_tool_use"
                case reasoning
            }

            struct Reasoning: Decodable {
                let allowedOptions: [String]?
                let defaultOption: String?

                enum CodingKeys: String, CodingKey {
                    case allowedOptions = "allowed_options"
                    case defaultOption = "default"
                }
            }
        }

        var resolvedContextLength: Int? {
            loadedInstances.first?.config.contextLength
                ?? loadedInstances.first?.config.maxContextLength
                ?? maxContextLength
        }

        var resolvedInputModalities: [String]? {
            guard type == "llm" else { return nil }
            var values = ["text"]
            if capabilities?.vision == true {
                values.append("image")
            }
            return values
        }

        var resolvedOutputModalities: [String]? {
            guard type == "llm" else { return nil }
            return ["text"]
        }

        var resolvedReasoningCapability: LLMReasoningCapability {
            let normalizedOptions = Set((capabilities?.reasoning?.allowedOptions ?? []).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            })

            guard normalizedOptions.contains("on"), normalizedOptions.contains("off") else {
                return .none
            }

            return LLMReasoningCapability(
                kind: .toggle,
                supportedEfforts: [],
                defaultEffort: nil,
                defaultEnabled: capabilities?.reasoning?.defaultOption?.lowercased() == "on"
            )
        }
    }
}

func decodeLMStudioNativeModelsForTests(from data: Data) throws -> [LLMProviderModel] {
    let decoded = try JSONDecoder().decode(LMStudioModelsResponse.self, from: data)
    return decoded.models.map { model in
        LLMProviderModel(
            id: model.key,
            name: model.displayName,
            description: model.description,
            contextLength: model.resolvedContextLength,
            createdAt: nil,
            inputModalities: model.resolvedInputModalities,
            outputModalities: model.resolvedOutputModalities,
            supportsVisionInput: model.capabilities?.vision,
            reasoningCapability: model.resolvedReasoningCapability
        )
    }
}

func shouldTryLMStudioNativeModelsMetadata(configuration: LLMConfiguration) -> Bool {
    let displayName = configuration.displayName.lowercased()
    if displayName.contains("lm studio") {
        return true
    }

    guard let host = configuration.baseURL?.host?.lowercased() else {
        return false
    }

    switch host {
    case "localhost", "127.0.0.1", "::1":
        return true
    default:
        return false
    }
}

func buildLMStudioNativeModelsURL(configuration: LLMConfiguration) -> URL? {
    guard let baseURL = configuration.baseURL else { return nil }
    var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
    components?.path = "/api/v1/models"
    components?.query = nil
    components?.fragment = nil
    return components?.url
}

func fetchLMStudioNativeModels(
    configuration: LLMConfiguration,
    urlSession: URLSession
) async throws -> [LLMProviderModel] {
    guard let modelsURL = buildLMStudioNativeModelsURL(configuration: configuration) else {
        return []
    }

    var request = URLRequest(url: modelsURL)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if !configuration.apiKey.isEmpty {
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
    }
    request.timeoutInterval = min(configuration.timeoutInterval, 15)

    let (data, response) = try await urlSession.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
        throw LLMError.unknown(message: "Invalid LM Studio models response type")
    }

    guard httpResponse.statusCode == 200 else {
        let body = String(data: data, encoding: .utf8) ?? "No response body"
        throw LLMError.unknown(message: "LM Studio native models HTTP \(httpResponse.statusCode): \(body)")
    }

    return try decodeLMStudioNativeModelsForTests(from: data)
}

func mergeProviderModels(
    primary: [LLMProviderModel],
    supplementary: [LLMProviderModel]
) -> [LLMProviderModel] {
    var supplementaryByID = Dictionary(uniqueKeysWithValues: supplementary.map { ($0.id, $0) })
    var merged: [LLMProviderModel] = primary.map { primaryModel in
        guard let supplementaryModel = supplementaryByID.removeValue(forKey: primaryModel.id) else {
            return primaryModel
        }

        return LLMProviderModel(
            id: primaryModel.id,
            name: primaryModel.name ?? supplementaryModel.name,
            description: normalizedSupplementaryDescription(primaryModel.description) ?? supplementaryModel.description,
            contextLength: primaryModel.contextLength ?? supplementaryModel.contextLength,
            createdAt: primaryModel.createdAt ?? supplementaryModel.createdAt,
            inputModalities: mergeSupplementaryModalities(primaryModel.inputModalities, supplementaryModel.inputModalities),
            outputModalities: mergeSupplementaryModalities(primaryModel.outputModalities, supplementaryModel.outputModalities),
            supportsVisionInput: primaryModel.supportsVisionInput ?? supplementaryModel.supportsVisionInput,
            reasoningCapability: primaryModel.reasoningCapability.kind == .none
                ? supplementaryModel.reasoningCapability
                : primaryModel.reasoningCapability
        )
    }

    merged.append(contentsOf: supplementaryByID.values)
    return LLMProviderModel.sortByVersionDescending(merged)
}

private func mergeSupplementaryModalities(_ primary: [String]?, _ supplementary: [String]?) -> [String]? {
    var merged: [String] = []
    var seen = Set<String>()

    for source in [primary, supplementary] {
        guard let source else { continue }
        for value in source {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { continue }
            merged.append(trimmed)
        }
    }

    return merged.isEmpty ? nil : merged
}

private func normalizedSupplementaryDescription(_ description: String?) -> String? {
    let trimmed = description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
}
