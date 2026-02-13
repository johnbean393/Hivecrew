import Foundation
import UniformTypeIdentifiers

struct MetadataFallbackExtractor: FileContentExtractor {
    let name = "metadata_fallback"

    func canHandle(fileURL _: URL, contentType _: UTType?) -> Bool {
        true
    }

    func extract(fileURL: URL, contentType: UTType?, policy _: IndexingPolicy) throws -> ExtractedContent? {
        var metadata = fileMetadata(fileURL: fileURL)
        if let contentTypeIdentifier = contentType?.identifier {
            metadata["uti"] = contentTypeIdentifier
        }
        return ExtractedContent(
            text: "",
            title: fileURL.lastPathComponent,
            metadata: metadata,
            warnings: ["metadata_only_fallback"]
        )
    }
}
