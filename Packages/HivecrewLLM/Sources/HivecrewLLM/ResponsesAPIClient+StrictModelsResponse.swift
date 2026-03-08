import Foundation

struct StrictModelsResponse: Decodable {
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
                .contextLength, .contextLengthCamel, .maxContextLength,
                .inputTokenLimit, .tokenLimit, .contextWindow
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
