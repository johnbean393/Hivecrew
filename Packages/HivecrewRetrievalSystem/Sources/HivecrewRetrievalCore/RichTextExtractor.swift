import AppKit
import Foundation
import UniformTypeIdentifiers

struct RichTextExtractor: FileContentExtractor {
    let name = "rich_text"

    private static let extensions: Set<String> = ["rtf", "rtfd", "html", "htm", "pages"]

    func canHandle(fileURL: URL, contentType _: UTType?) -> Bool {
        Self.extensions.contains(fileURL.pathExtension.lowercased())
    }

    func extract(fileURL: URL, contentType _: UTType?, policy _: IndexingPolicy) throws -> ExtractedContent? {
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

        // pages is best-effort in this phase; fallback to metadata if parser fails.
        return ExtractedContent(
            text: "",
            title: fileURL.lastPathComponent,
            metadata: fileMetadata(fileURL: fileURL),
            warnings: warnings
        )
    }
}
