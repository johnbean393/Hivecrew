//
//  LLMProviderModel.swift
//  HivecrewLLM
//
//  Normalized model metadata returned by provider /models endpoints.
//

import Foundation

/// A normalized model descriptor for model-picking UIs.
///
/// Fields are intentionally optional so clients can parse richer providers
/// (such as OpenRouter) while still supporting minimal OpenAI-compatible
/// responses that only include an `id`.
public struct LLMProviderModel: Sendable, Codable, Hashable, Identifiable {
    /// Provider model identifier used in requests.
    public let id: String

    /// Human-friendly model name if provided by the upstream API.
    public let name: String?

    /// Provider-supplied model description.
    public let description: String?

    /// Maximum context window size in tokens.
    public let contextLength: Int?

    /// Timestamp associated with the model metadata (provider-defined).
    public let createdAt: Date?

    /// Supported input modalities, e.g. ["text", "image"].
    public let inputModalities: [String]?

    /// Supported output modalities, e.g. ["text"].
    public let outputModalities: [String]?

    /// Optional provider-supplied signal indicating whether image input is supported.
    /// When present, this takes precedence over inferred modality parsing.
    public let supportsVisionInput: Bool?

    public init(
        id: String,
        name: String? = nil,
        description: String? = nil,
        contextLength: Int? = nil,
        createdAt: Date? = nil,
        inputModalities: [String]? = nil,
        outputModalities: [String]? = nil,
        supportsVisionInput: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.contextLength = contextLength
        self.createdAt = createdAt
        self.inputModalities = inputModalities
        self.outputModalities = outputModalities
        self.supportsVisionInput = supportsVisionInput
    }

    /// Fallback-safe display title for UI surfaces.
    public var displayName: String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? id : trimmed
    }

    /// Best-effort signal for image/vision input support.
    public var isVisionCapable: Bool {
        if let supportsVisionInput {
            return supportsVisionInput
        }
        guard let inputModalities else { return false }
        return inputModalities.contains { modality in
            Self.isVisionModality(modality)
        }
    }

    private static func isVisionModality(_ rawValue: String) -> Bool {
        let normalized = rawValue
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
}
