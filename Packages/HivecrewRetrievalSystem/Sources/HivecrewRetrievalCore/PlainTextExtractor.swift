import Foundation
import UniformTypeIdentifiers

struct PlainTextExtractor: FileContentExtractor {
    let name = "plain_text"

    private static let handledExtensions: Set<String> = [
        "txt", "md", "markdown", "json", "yaml", "yml", "toml", "csv", "tsv", "sql", "xml",
        "swift", "kt", "js", "ts", "tsx", "jsx", "py", "go", "rs", "rb", "java", "c", "cpp",
        "h", "hpp", "m", "mm", "sh", "zsh", "bash", "eml", "ics", "log", "ini", "conf",
    ]

    func canHandle(fileURL: URL, contentType: UTType?) -> Bool {
        let ext = fileURL.pathExtension.lowercased()
        if Self.handledExtensions.contains(ext) {
            return true
        }
        guard let contentType else { return false }
        return contentType.conforms(to: .plainText) || contentType.conforms(to: .sourceCode)
    }

    func extract(fileURL: URL, contentType _: UTType?, policy: IndexingPolicy) throws -> ExtractedContent? {
        let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
        let fileSize = max(0, values?.fileSize ?? 0)
        // Avoid loading very large text-like files fully into memory. A prefix is enough
        // for retrieval indexing and prevents timeouts on generated JSON artifacts.
        let maxReadBytes = max(
            512 * 1_024,
            min(Int(policy.hardFileSizeCapBytes), policy.maxExtractedCharactersPerDocument * 6)
        )
        let readLimit = fileSize > 0 ? min(fileSize, maxReadBytes) : maxReadBytes
        let data = try readPrefixData(from: fileURL, maxBytes: readLimit)
        let encodings: [String.Encoding] = [.utf8, .utf16, .utf32, .isoLatin1, .macOSRoman]
        for encoding in encodings {
            if let body = String(data: data, encoding: encoding), !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                var warnings: [String] = []
                if fileSize > readLimit {
                    warnings.append("text_truncated_large_file")
                }
                return ExtractedContent(
                    text: body,
                    title: fileURL.lastPathComponent,
                    metadata: fileMetadata(fileURL: fileURL),
                    warnings: warnings
                )
            }
        }
        return nil
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
