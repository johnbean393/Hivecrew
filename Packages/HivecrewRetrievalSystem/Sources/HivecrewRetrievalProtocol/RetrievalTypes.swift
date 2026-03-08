import Foundation

public enum RetrievalSourceType: String, Codable, Sendable, CaseIterable {
    case file
    case email
    case message
    case calendar
}

public enum RetrievalInjectionMode: String, Codable, Sendable, CaseIterable {
    case fileRef
    case inlineSnippet
    case structuredSummary

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "fileRef", "file_ref":
            self = .fileRef
        case "inlineSnippet", "inline_snippet":
            self = .inlineSnippet
        case "structuredSummary", "structured_summary":
            self = .structuredSummary
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown RetrievalInjectionMode value: \(raw)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum RetrievalRiskLabel: String, Codable, Sendable, CaseIterable {
    case low
    case medium
    case high
}

public enum RetrievalOperationPhase: String, Codable, Sendable, CaseIterable {
    case idle
    case scanning
    case extracting
    case ingesting
    case backfilling
}
