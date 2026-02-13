import Foundation
import UniformTypeIdentifiers

public enum ExtractionOutcomeKind: String, Sendable, Codable {
    case success
    case partial
    case failed
    case unsupported
}

public struct ExtractionTelemetry: Sendable, Codable {
    public let outcome: ExtractionOutcomeKind
    public let usedOCR: Bool
    public let format: String
    public let detail: String?
}

public struct ExtractedContent: Sendable {
    public let text: String
    public let title: String?
    public let metadata: [String: String]
    public let warnings: [String]
    public let wasOCRUsed: Bool

    public init(
        text: String,
        title: String? = nil,
        metadata: [String: String] = [:],
        warnings: [String] = [],
        wasOCRUsed: Bool = false
    ) {
        self.text = text
        self.title = title
        self.metadata = metadata
        self.warnings = warnings
        self.wasOCRUsed = wasOCRUsed
    }

    public func searchableBody(maxCharacters: Int) -> String {
        var blocks: [String] = []
        let cleanedText = Self.normalize(text)
        if !cleanedText.isEmpty {
            blocks.append(cleanedText)
        }

        if !metadata.isEmpty {
            let lines = metadata
                .sorted(by: { $0.key < $1.key })
                .prefix(16)
                .map { "\($0.key): \($0.value)" }
            if !lines.isEmpty {
                blocks.append("Metadata\n" + lines.joined(separator: "\n"))
            }
        }

        let combined = blocks.joined(separator: "\n\n")
        guard combined.count > maxCharacters else {
            return combined
        }
        let cut = combined.index(combined.startIndex, offsetBy: max(0, maxCharacters))
        return String(combined[..<cut])
    }

    private static func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct FileExtractionResult: Sendable {
    public let content: ExtractedContent?
    public let telemetry: ExtractionTelemetry

    public init(content: ExtractedContent?, telemetry: ExtractionTelemetry) {
        self.content = content
        self.telemetry = telemetry
    }
}

protocol FileContentExtractor: Sendable {
    var name: String { get }
    func canHandle(fileURL: URL, contentType: UTType?) -> Bool
    func extract(fileURL: URL, contentType: UTType?, policy: IndexingPolicy) throws -> ExtractedContent?
}
