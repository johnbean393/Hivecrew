//
//  LLMProviderModel.swift
//  HivecrewLLM
//
//  Normalized model metadata returned by provider /models endpoints.
//

import Foundation

public enum LLMReasoningCapabilityKind: String, Sendable, Codable, Hashable {
    case none
    case toggle
    case effort
}

public struct LLMReasoningCapability: Sendable, Codable, Hashable {
    public let kind: LLMReasoningCapabilityKind
    public let supportedEfforts: [String]
    public let defaultEffort: String?
    public let defaultEnabled: Bool

    public init(
        kind: LLMReasoningCapabilityKind = .none,
        supportedEfforts: [String] = [],
        defaultEffort: String? = nil,
        defaultEnabled: Bool = false
    ) {
        self.kind = kind
        self.supportedEfforts = supportedEfforts
        self.defaultEffort = defaultEffort
        self.defaultEnabled = defaultEnabled
    }

    public static let none = LLMReasoningCapability()
}

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

    /// Provider-supplied reasoning configuration support.
    public let reasoningCapability: LLMReasoningCapability

    public init(
        id: String,
        name: String? = nil,
        description: String? = nil,
        contextLength: Int? = nil,
        createdAt: Date? = nil,
        inputModalities: [String]? = nil,
        outputModalities: [String]? = nil,
        supportsVisionInput: Bool? = nil,
        reasoningCapability: LLMReasoningCapability = .none
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.contextLength = contextLength
        self.createdAt = createdAt
        self.inputModalities = inputModalities
        self.outputModalities = outputModalities
        self.supportsVisionInput = supportsVisionInput
        self.reasoningCapability = reasoningCapability
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

    public var supportsReasoningControl: Bool {
        reasoningCapability.kind != .none
    }

    /// Shared sort used by model-picking UIs and provider clients.
    ///
    /// Models are grouped by their textual tokens in ascending order, while any
    /// numeric version tokens are compared in descending order so newer
    /// versions surface first (for example `gpt-5.4` before `gpt-5.1` and
    /// `aion-2.0` before `aion-1.0`).
    public static func versionDescendingComparator(_ lhs: Self, _ rhs: Self) -> Bool {
        compareForVersionDescending(lhs, rhs) == .orderedAscending
    }

    public static func sortByVersionDescending(_ models: [Self]) -> [Self] {
        models.sorted(by: versionDescendingComparator)
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

    private var primarySortText: String {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedName.isEmpty ? id : trimmedName
    }

    private enum SortToken: Equatable {
        case word(String)
        case number(String)
    }

    private static func compareForVersionDescending(_ lhs: Self, _ rhs: Self) -> ComparisonResult {
        let primaryComparison = compareVersionAwareText(lhs.primarySortText, rhs.primarySortText)
        if primaryComparison != .orderedSame {
            return primaryComparison
        }

        let identifierComparison = compareVersionAwareText(lhs.id, rhs.id)
        if identifierComparison != .orderedSame {
            return identifierComparison
        }

        return lhs.displayName.localizedStandardCompare(rhs.displayName)
    }

    private static func compareVersionAwareText(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lhsTokens = tokenizeVersionAwareText(lhs)
        let rhsTokens = tokenizeVersionAwareText(rhs)
        let sharedCount = min(lhsTokens.count, rhsTokens.count)

        for index in 0..<sharedCount {
            let lhsToken = lhsTokens[index]
            let rhsToken = rhsTokens[index]

            guard lhsToken != rhsToken else {
                continue
            }

            switch (lhsToken, rhsToken) {
            case let (.number(lhsNumber), .number(rhsNumber)):
                let numericComparison = compareNumericStringsDescending(lhsNumber, rhsNumber)
                if numericComparison != .orderedSame {
                    return numericComparison
                }
            case let (.word(lhsWord), .word(rhsWord)):
                let wordComparison = lhsWord.localizedCaseInsensitiveCompare(rhsWord)
                if wordComparison != .orderedSame {
                    return wordComparison
                }
                let fallbackComparison = lhsWord.compare(rhsWord)
                if fallbackComparison != .orderedSame {
                    return fallbackComparison
                }
            case (.number, .word):
                return .orderedAscending
            case (.word, .number):
                return .orderedDescending
            }
        }

        if lhsTokens.count != rhsTokens.count {
            let lhsHasRemainingTokens = lhsTokens.count > sharedCount
            let nextToken = lhsHasRemainingTokens ? lhsTokens[sharedCount] : rhsTokens[sharedCount]

            switch nextToken {
            case .number:
                return lhsHasRemainingTokens ? .orderedAscending : .orderedDescending
            case .word:
                return lhsHasRemainingTokens ? .orderedDescending : .orderedAscending
            }
        }

        return lhs.localizedStandardCompare(rhs)
    }

    private static func tokenizeVersionAwareText(_ text: String) -> [SortToken] {
        var tokens: [SortToken] = []
        var current = ""
        var currentIsNumber: Bool?

        func flushCurrent() {
            guard !current.isEmpty, let currentIsNumber else { return }
            tokens.append(currentIsNumber ? .number(current) : .word(current.lowercased()))
            current.removeAll(keepingCapacity: true)
        }

        for scalar in text.unicodeScalars {
            if CharacterSet.decimalDigits.contains(scalar) {
                if currentIsNumber == false {
                    flushCurrent()
                }
                current.append(String(scalar))
                currentIsNumber = true
                continue
            }

            if CharacterSet.letters.contains(scalar) {
                if currentIsNumber == true {
                    flushCurrent()
                }
                current.append(String(scalar))
                currentIsNumber = false
                continue
            }

            flushCurrent()
            currentIsNumber = nil
        }

        flushCurrent()
        return tokens
    }

    private static func compareNumericStringsDescending(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let normalizedLHS = lhs.drop { $0 == "0" }
        let normalizedRHS = rhs.drop { $0 == "0" }
        let lhsDigits = normalizedLHS.isEmpty ? "0" : String(normalizedLHS)
        let rhsDigits = normalizedRHS.isEmpty ? "0" : String(normalizedRHS)

        if lhsDigits.count != rhsDigits.count {
            return lhsDigits.count > rhsDigits.count ? .orderedAscending : .orderedDescending
        }

        if lhsDigits != rhsDigits {
            return lhsDigits > rhsDigits ? .orderedAscending : .orderedDescending
        }

        if lhs.count != rhs.count {
            return lhs.count < rhs.count ? .orderedAscending : .orderedDescending
        }

        return .orderedSame
    }
}
