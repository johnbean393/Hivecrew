//
//  OpenAICompatibleModelsResponse.swift
//  HivecrewLLM
//
//  Decoding models for OpenAI-compatible /v1/models responses
//

import Foundation

/// Response from /v1/models endpoint
struct ModelsResponse: Decodable {
    let data: [ModelInfo]

    struct ModelInfo: Decodable {
        let id: String
        let name: String?
        let description: String?
        let created: Int?
        let contextLength: Int?
        let architecture: Architecture?
        let topProvider: TopProvider?
        let topLevelInputModalities: [String]?
        let topLevelOutputModalities: [String]?
        let modalities: Modalities?
        let capabilities: Capabilities?
        let visionFlag: Bool?
        let supportsVisionFlag: Bool?
        let imageInputFlag: Bool?
        let supportsImageInputFlag: Bool?
        let supportedParameters: [String]?

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case description
            case created
            case contextLength = "context_length"
            case contextLengthCamel = "contextLength"
            case maxContextLength = "max_context_length"
            case maxInputTokens = "max_input_tokens"
            case inputTokenLimit = "input_token_limit"
            case inputTokenLimitCamel = "inputTokenLimit"
            case tokenLimit = "token_limit"
            case architecture
            case topProvider = "top_provider"
            case topLevelInputModalities = "input_modalities"
            case topLevelOutputModalities = "output_modalities"
            case inputModalitiesCamel = "inputModalities"
            case outputModalitiesCamel = "outputModalities"
            case modalities
            case capabilities
            case visionFlag = "vision"
            case supportsVisionFlag = "supports_vision"
            case supportsVisionFlagCamel = "supportsVision"
            case imageInputFlag = "image_input"
            case imageInputFlagCamel = "imageInput"
            case supportsImageInputFlag = "supports_image_input"
            case supportsImageInputFlagCamel = "supportsImageInput"
            case supportedParameters = "supported_parameters"
        }

        struct Architecture: Decodable {
            let inputModalities: [String]?
            let outputModalities: [String]?

            enum CodingKeys: String, CodingKey {
                case inputModalities = "input_modalities"
                case outputModalities = "output_modalities"
            }
        }

        struct TopProvider: Decodable {
            let contextLength: Int?

            enum CodingKeys: String, CodingKey {
                case contextLength = "context_length"
                case contextLengthCamel = "contextLength"
                case maxContextLength = "max_context_length"
                case maxInputTokens = "max_input_tokens"
                case inputTokenLimit = "input_token_limit"
                case inputTokenLimitCamel = "inputTokenLimit"
                case tokenLimit = "token_limit"
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.contextLength = Self.decodeInt(
                    from: container,
                    keys: [
                        .contextLength,
                        .contextLengthCamel,
                        .maxContextLength,
                        .maxInputTokens,
                        .inputTokenLimit,
                        .inputTokenLimitCamel,
                        .tokenLimit
                    ]
                )
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
        }

        struct Modalities: Decodable {
            let input: [String]?
            let output: [String]?

            enum CodingKeys: String, CodingKey {
                case input
                case inputs
                case inputModalitiesSnake = "input_modalities"
                case inputModalitiesCamel = "inputModalities"
                case output
                case outputs
                case outputModalitiesSnake = "output_modalities"
                case outputModalitiesCamel = "outputModalities"
            }

            init(from decoder: Decoder) throws {
                if let singleArray = try? decoder.singleValueContainer().decode([String].self) {
                    self.input = singleArray
                    self.output = nil
                    return
                }

                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.input = Self.decodeModalityValues(
                    from: container,
                    keys: [.input, .inputs, .inputModalitiesSnake, .inputModalitiesCamel]
                )
                self.output = Self.decodeModalityValues(
                    from: container,
                    keys: [.output, .outputs, .outputModalitiesSnake, .outputModalitiesCamel]
                )
            }

            private static func decodeModalityValues(
                from container: KeyedDecodingContainer<CodingKeys>,
                keys: [CodingKeys]
            ) -> [String]? {
                for key in keys {
                    if let values = try? container.decodeIfPresent([String].self, forKey: key) {
                        return values
                    }
                    if let value = try? container.decodeIfPresent(String.self, forKey: key) {
                        return [value]
                    }
                }
                return nil
            }
        }

        struct Capabilities: Decodable {
            let visionFlag: Bool?
            let supportsVisionFlag: Bool?
            let imageInputFlag: Bool?
            let supportsImageInputFlag: Bool?

            enum CodingKeys: String, CodingKey {
                case visionFlag = "vision"
                case supportsVisionFlag = "supports_vision"
                case supportsVisionFlagCamel = "supportsVision"
                case imageInputFlag = "image_input"
                case imageInputFlagCamel = "imageInput"
                case supportsImageInputFlag = "supports_image_input"
                case supportsImageInputFlagCamel = "supportsImageInput"
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.visionFlag = Self.decodeBool(from: container, keys: [.visionFlag])
                self.supportsVisionFlag = Self.decodeBool(from: container, keys: [.supportsVisionFlag, .supportsVisionFlagCamel])
                self.imageInputFlag = Self.decodeBool(from: container, keys: [.imageInputFlag, .imageInputFlagCamel])
                self.supportsImageInputFlag = Self.decodeBool(from: container, keys: [.supportsImageInputFlag, .supportsImageInputFlagCamel])
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
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decode(String.self, forKey: .id)
            self.name = try? container.decodeIfPresent(String.self, forKey: .name)
            self.description = try? container.decodeIfPresent(String.self, forKey: .description)
            self.created = try? container.decodeIfPresent(Int.self, forKey: .created)
            self.contextLength = Self.decodeInt(
                from: container,
                keys: [
                    .contextLength,
                    .contextLengthCamel,
                    .maxContextLength,
                    .maxInputTokens,
                    .inputTokenLimit,
                    .inputTokenLimitCamel,
                    .tokenLimit
                ]
            )
            self.architecture = try? container.decodeIfPresent(Architecture.self, forKey: .architecture)
            self.topProvider = try? container.decodeIfPresent(TopProvider.self, forKey: .topProvider)
            self.topLevelInputModalities = Self.decodeModalities(
                from: container,
                snakeCaseKey: .topLevelInputModalities,
                camelCaseKey: .inputModalitiesCamel
            )
            self.topLevelOutputModalities = Self.decodeModalities(
                from: container,
                snakeCaseKey: .topLevelOutputModalities,
                camelCaseKey: .outputModalitiesCamel
            )
            self.modalities = try? container.decodeIfPresent(Modalities.self, forKey: .modalities)
            self.capabilities = try? container.decodeIfPresent(Capabilities.self, forKey: .capabilities)
            self.visionFlag = Self.decodeBool(from: container, keys: [.visionFlag])
            self.supportsVisionFlag = Self.decodeBool(from: container, keys: [.supportsVisionFlag, .supportsVisionFlagCamel])
            self.imageInputFlag = Self.decodeBool(from: container, keys: [.imageInputFlag, .imageInputFlagCamel])
            self.supportsImageInputFlag = Self.decodeBool(from: container, keys: [.supportsImageInputFlag, .supportsImageInputFlagCamel])
            self.supportedParameters = try? container.decodeIfPresent([String].self, forKey: .supportedParameters)
        }

        var normalizedInputModalities: [String]? {
            Self.mergeModalities(
                architecture?.inputModalities,
                topLevelInputModalities,
                modalities?.input
            )
        }

        var normalizedOutputModalities: [String]? {
            Self.mergeModalities(
                architecture?.outputModalities,
                topLevelOutputModalities,
                modalities?.output
            )
        }

        var normalizedSupportsVisionInput: Bool? {
            let directFlags: [Bool?] = [
                visionFlag,
                supportsVisionFlag,
                imageInputFlag,
                supportsImageInputFlag,
                capabilities?.visionFlag,
                capabilities?.supportsVisionFlag,
                capabilities?.imageInputFlag,
                capabilities?.supportsImageInputFlag
            ]
            if directFlags.contains(true) {
                return true
            }
            if directFlags.contains(false) {
                return false
            }
            guard let input = normalizedInputModalities else {
                return nil
            }
            let hasVisionModality = input.contains { modality in
                let normalized = modality
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                    .replacingOccurrences(of: "-", with: "_")
                switch normalized {
                case "image", "images", "vision", "image_url", "imageurl", "multimodal":
                    return true
                default:
                    return false
                }
            }
            return hasVisionModality ? true : nil
        }

        var normalizedReasoningCapability: LLMReasoningCapability {
            let parameters = Set((supportedParameters ?? []).map { $0.lowercased() })
            guard parameters.contains("reasoning") else {
                return .none
            }
            return LLMReasoningCapability(
                kind: .toggle,
                supportedEfforts: [],
                defaultEffort: nil,
                defaultEnabled: true
            )
        }

        private static func decodeModalities(
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

        private static func mergeModalities(_ arrays: [String]?...) -> [String]? {
            var seen: Set<String> = []
            var merged: [String] = []
            for values in arrays {
                guard let values else { continue }
                for raw in values {
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    let key = trimmed.lowercased()
                    if seen.insert(key).inserted {
                        merged.append(trimmed)
                    }
                }
            }
            return merged.isEmpty ? nil : merged
        }
    }
}
