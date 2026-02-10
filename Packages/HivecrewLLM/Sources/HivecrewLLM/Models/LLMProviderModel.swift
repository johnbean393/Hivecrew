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

    public init(
        id: String,
        name: String? = nil,
        description: String? = nil,
        contextLength: Int? = nil,
        createdAt: Date? = nil,
        inputModalities: [String]? = nil,
        outputModalities: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.contextLength = contextLength
        self.createdAt = createdAt
        self.inputModalities = inputModalities
        self.outputModalities = outputModalities
    }

    /// Fallback-safe display title for UI surfaces.
    public var displayName: String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? id : trimmed
    }

    /// Best-effort signal for image/vision input support.
    public var isVisionCapable: Bool {
        guard let inputModalities else { return false }
        let normalized = inputModalities.map { $0.lowercased() }
        return normalized.contains { modality in
            modality == "image" || modality == "vision"
        }
    }
}
