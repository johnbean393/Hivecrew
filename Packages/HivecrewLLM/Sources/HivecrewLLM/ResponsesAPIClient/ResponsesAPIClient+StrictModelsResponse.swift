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
        let architecture: Architecture?
        let inputModalities: [String]?
        let outputModalities: [String]?
        let modalities: Modalities?
        let capabilities: Capabilities?
        let supportsVision: Bool?
        let supportedReasoningLevels: [ReasoningLevel]?
        let supportedParameters: [String]?
        let defaultReasoningLevel: String?
        let isSupportedInAPI: Bool

        struct ReasoningLevel: Decodable {
            let effort: String
        }

        struct Architecture: Decodable {
            let modality: String?
            let inputModalities: [String]?
            let outputModalities: [String]?

            enum CodingKeys: String, CodingKey {
                case modality
                case inputModalities = "input_modalities"
                case outputModalities = "output_modalities"
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
                self.input = Self.decodeStringArray(
                    from: container,
                    keys: [.input, .inputs, .inputModalitiesSnake, .inputModalitiesCamel]
                )
                self.output = Self.decodeStringArray(
                    from: container,
                    keys: [.output, .outputs, .outputModalitiesSnake, .outputModalitiesCamel]
                )
            }

            private static func decodeStringArray(
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
            let vision: Bool?
            let supportsVision: Bool?
            let imageInput: Bool?
            let supportsImageInput: Bool?

            enum CodingKeys: String, CodingKey {
                case vision
                case supportsVision = "supports_vision"
                case supportsVisionCamel = "supportsVision"
                case imageInput = "image_input"
                case imageInputCamel = "imageInput"
                case supportsImageInput = "supports_image_input"
                case supportsImageInputCamel = "supportsImageInput"
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                vision = Self.decodeBool(from: container, keys: [.vision])
                supportsVision = Self.decodeBool(from: container, keys: [.supportsVision, .supportsVisionCamel])
                imageInput = Self.decodeBool(from: container, keys: [.imageInput, .imageInputCamel])
                supportsImageInput = Self.decodeBool(from: container, keys: [.supportsImageInput, .supportsImageInputCamel])
            }

            private static func decodeBool(
                from container: KeyedDecodingContainer<CodingKeys>,
                keys: [CodingKeys]
            ) -> Bool? {
                for key in keys {
                    if let value = try? container.decodeIfPresent(Bool.self, forKey: key) {
                        return value
                    }
                    if let value = try? container.decodeIfPresent(String.self, forKey: key) {
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
            case architecture
            case inputModalities = "input_modalities"
            case inputModalitiesCamel = "inputModalities"
            case outputModalities = "output_modalities"
            case outputModalitiesCamel = "outputModalities"
            case modalities
            case capabilities
            case vision = "vision"
            case supportsVision = "supports_vision"
            case supportsVisionCamel = "supportsVision"
            case imageInput = "image_input"
            case imageInputCamel = "imageInput"
            case supportsImageInput = "supports_image_input"
            case supportsImageInputCamel = "supportsImageInput"
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

            architecture = try? container.decodeIfPresent(Architecture.self, forKey: .architecture)
            let topLevelInputModalities = Self.decodeStringArray(
                from: container,
                snakeCaseKey: .inputModalities,
                camelCaseKey: .inputModalitiesCamel
            )
            let topLevelOutputModalities = Self.decodeStringArray(
                from: container,
                snakeCaseKey: .outputModalities,
                camelCaseKey: .outputModalitiesCamel
            )
            modalities = try? container.decodeIfPresent(Modalities.self, forKey: .modalities)
            capabilities = try? container.decodeIfPresent(Capabilities.self, forKey: .capabilities)

            let derivedModalities = architecture?.modality.flatMap(Self.parseArchitectureModality)
            inputModalities = Self.mergeModalities(
                architecture?.inputModalities,
                derivedModalities?.input,
                topLevelInputModalities,
                modalities?.input
            )
            outputModalities = Self.mergeModalities(
                architecture?.outputModalities,
                derivedModalities?.output,
                topLevelOutputModalities,
                modalities?.output
            )

            let directVisionFlags: [Bool?] = [
                Self.decodeBool(
                    from: container,
                    keys: [
                        .supportsVision,
                        .supportsVisionCamel,
                        .vision,
                        .imageInput,
                        .imageInputCamel,
                        .supportsImageInput,
                        .supportsImageInputCamel,
                        .supportsImageDetailOriginal
                    ]
                ),
                capabilities?.vision,
                capabilities?.supportsVision,
                capabilities?.imageInput,
                capabilities?.supportsImageInput
            ]
            if directVisionFlags.contains(true) {
                supportsVision = true
            } else if directVisionFlags.contains(false) {
                supportsVision = false
            } else {
                supportsVision = inputModalities?.contains(where: Self.isVisionModality)
            }

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
                if let value = try? container.decodeIfPresent(String.self, forKey: key) {
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

        private static func mergeModalities(_ sources: [String]?...) -> [String]? {
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

        private static func isVisionModality(_ value: String) -> Bool {
            let normalized = value
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

        private static func parseArchitectureModality(_ rawValue: String) -> (input: [String], output: [String])? {
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            let segments = trimmed.split(separator: ">", maxSplits: 1, omittingEmptySubsequences: false)
            let inputSegment = segments.first.map(String.init) ?? trimmed
            let outputSegment = segments.count > 1 ? String(segments[1]) : ""

            let input = parseModalityTokens(inputSegment.replacingOccurrences(of: "-", with: ""))
            let output = parseModalityTokens(outputSegment.replacingOccurrences(of: "-", with: ""))

            if input.isEmpty, output.isEmpty {
                return nil
            }

            return (input, output)
        }

        private static func parseModalityTokens(_ rawValue: String) -> [String] {
            rawValue
                .split(separator: "+")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        }
    }
}
