import Foundation
import UniformTypeIdentifiers

func timeoutFallbackResult(fileURL: URL, format: String) -> FileExtractionResult {
    var metadata = fileMetadata(fileURL: fileURL)
    metadata["extractionTimeout"] = "true"
    return FileExtractionResult(
        content: ExtractedContent(
            text: fileURL.lastPathComponent,
            title: fileURL.lastPathComponent,
            metadata: metadata,
            warnings: ["extraction_timeout_metadata_only"],
            wasOCRUsed: false
        ),
        telemetry: ExtractionTelemetry(
            outcome: .partial,
            usedOCR: false,
            format: format,
            detail: "timeout"
        )
    )
}

func performExtraction(
    extractor: any FileContentExtractor,
    fileURL: URL,
    contentType: UTType?,
    policy: IndexingPolicy
) -> FileExtractionResult {
    do {
        guard let extracted = try extractor.extract(fileURL: fileURL, contentType: contentType, policy: policy) else {
            return FileExtractionResult(
                content: nil,
                telemetry: ExtractionTelemetry(
                    outcome: .unsupported,
                    usedOCR: false,
                    format: extractor.name,
                    detail: "no_content"
                )
            )
        }
        let body = extracted.searchableBody(maxCharacters: policy.maxExtractedCharactersPerDocument)
        let normalized = ExtractedContent(
            text: body,
            title: extracted.title,
            metadata: extracted.metadata,
            warnings: extracted.warnings,
            wasOCRUsed: extracted.wasOCRUsed
        )
        let hasSourceText = !extracted.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let warningSet = Set(normalized.warnings)
        if !hasSourceText,
            !warningSet.isEmpty,
            warningSet.isSubset(of: unsupportedWithoutSourceTextWarnings)
        {
            return FileExtractionResult(
                content: nil,
                telemetry: ExtractionTelemetry(
                    outcome: .unsupported,
                    usedOCR: normalized.wasOCRUsed,
                    format: extractor.name,
                    detail: normalized.warnings.first
                )
            )
        }
        let outcome: ExtractionOutcomeKind
        if body.isEmpty {
            outcome = .unsupported
        } else if normalized.warnings.isEmpty {
            outcome = .success
        } else if warningSet.isSubset(of: warningsThatStillCountAsSuccess) {
            outcome = .success
        } else {
            outcome = .partial
        }
        return FileExtractionResult(
            content: normalized,
            telemetry: ExtractionTelemetry(
                outcome: outcome,
                usedOCR: normalized.wasOCRUsed,
                format: extractor.name,
                detail: normalized.warnings.first
            )
        )
    } catch {
        return FileExtractionResult(
            content: nil,
            telemetry: ExtractionTelemetry(
                outcome: .failed,
                usedOCR: false,
                format: extractor.name,
                detail: error.localizedDescription
            )
        )
    }
}

private let unsupportedWithoutSourceTextWarnings: Set<String> = [
    "metadata_only_fallback",
    "image_ocr_empty",
    "image_ocr_skipped_size_limit",
    "image_decode_failed",
    "openxml_empty_text",
    "rich_text_empty",
    "rich_text_parse_failed",
]

private let warningsThatStillCountAsSuccess: Set<String> = [
    "text_truncated_large_file",
]

final class CompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func resumeOnce(_ block: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else {
            return
        }
        completed = true
        block()
    }
}
