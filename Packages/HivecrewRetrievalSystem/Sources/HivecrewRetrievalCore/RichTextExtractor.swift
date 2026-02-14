import AppKit
import Foundation
import UniformTypeIdentifiers

struct RichTextExtractor: FileContentExtractor {
    let name = "rich_text"

    private static let extensions: Set<String> = ["rtf", "rtfd", "html", "htm", "pages", "doc", "docm", "dot"]
    private static let legacyWordExtensions: Set<String> = ["doc", "docm", "dot"]

    func canHandle(fileURL: URL, contentType _: UTType?) -> Bool {
        Self.extensions.contains(fileURL.pathExtension.lowercased())
    }

    func extract(fileURL: URL, contentType _: UTType?, policy: IndexingPolicy) throws -> ExtractedContent? {
        let ext = fileURL.pathExtension.lowercased()
        var warnings: [String] = []
        do {
            let attributed = try NSAttributedString(url: fileURL, options: [:], documentAttributes: nil)
            let text = attributed.string
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return ExtractedContent(
                    text: text,
                    title: fileURL.lastPathComponent,
                    metadata: fileMetadata(fileURL: fileURL),
                    warnings: warnings
                )
            }
            warnings.append("rich_text_empty")
        } catch {
            warnings.append("rich_text_parse_failed")
        }

        if Self.legacyWordExtensions.contains(ext),
           let heuristicText = try legacyWordHeuristicText(fileURL: fileURL, policy: policy),
           !heuristicText.isEmpty {
            warnings.append("legacy_word_binary_heuristic")
            return ExtractedContent(
                text: heuristicText,
                title: fileURL.lastPathComponent,
                metadata: fileMetadata(fileURL: fileURL),
                warnings: warnings
            )
        }

        // pages is best-effort in this phase; fallback to metadata if parser fails.
        return ExtractedContent(
            text: "",
            title: fileURL.lastPathComponent,
            metadata: fileMetadata(fileURL: fileURL),
            warnings: warnings
        )
    }

    private func legacyWordHeuristicText(fileURL: URL, policy: IndexingPolicy) throws -> String? {
        let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
        let fileSize = max(0, values?.fileSize ?? 0)
        let maxReadBytes = max(
            512 * 1_024,
            min(Int(policy.hardFileSizeCapBytes), policy.maxExtractedCharactersPerDocument * 10)
        )
        let readLimit = fileSize > 0 ? min(fileSize, maxReadBytes) : maxReadBytes
        let data = try readPrefixData(from: fileURL, maxBytes: readLimit)
        guard !data.isEmpty else { return nil }

        let utf16Runs = extractUTF16LERuns(from: data, minimumLength: 4)
        let asciiRuns = extractASCIIRuns(from: data, minimumLength: 4)
        var seen = Set<String>()
        var merged: [String] = []
        for run in utf16Runs + asciiRuns {
            let cleaned = collapseWhitespace(run)
            guard cleaned.count >= 4 else { continue }
            guard !seen.contains(cleaned) else { continue }
            seen.insert(cleaned)
            merged.append(cleaned)
        }
        guard !merged.isEmpty else { return nil }
        let joined = merged.joined(separator: "\n")
        return String(joined.prefix(policy.maxExtractedCharactersPerDocument))
    }

    private func extractASCIIRuns(from data: Data, minimumLength: Int) -> [String] {
        var runs: [String] = []
        var buffer: [UInt8] = []
        buffer.reserveCapacity(64)
        for byte in data {
            if byte == 9 || byte == 10 || byte == 13 || (32...126).contains(byte) {
                buffer.append(byte)
            } else {
                if buffer.count >= minimumLength {
                    runs.append(String(decoding: buffer, as: UTF8.self))
                }
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if buffer.count >= minimumLength {
            runs.append(String(decoding: buffer, as: UTF8.self))
        }
        return runs
    }

    private func extractUTF16LERuns(from data: Data, minimumLength: Int) -> [String] {
        var runs: [String] = []
        var scalars: [UInt8] = []
        scalars.reserveCapacity(64)

        let bytes = [UInt8](data)
        var index = 0
        while index + 1 < bytes.count {
            let low = bytes[index]
            let high = bytes[index + 1]
            if high == 0 && (low == 9 || low == 10 || low == 13 || (32...126).contains(low)) {
                scalars.append(low)
            } else {
                if scalars.count >= minimumLength {
                    runs.append(String(decoding: scalars, as: UTF8.self))
                }
                scalars.removeAll(keepingCapacity: true)
            }
            index += 2
        }
        if scalars.count >= minimumLength {
            runs.append(String(decoding: scalars, as: UTF8.self))
        }
        return runs
    }

    private func collapseWhitespace(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func readPrefixData(from fileURL: URL, maxBytes: Int) throws -> Data {
        guard maxBytes > 0 else { return Data() }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        if #available(macOS 12.0, *) {
            return try handle.read(upToCount: maxBytes) ?? Data()
        }
        return handle.readData(ofLength: maxBytes)
    }
}
