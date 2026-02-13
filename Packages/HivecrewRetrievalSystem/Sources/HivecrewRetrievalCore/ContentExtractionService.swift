import Foundation
import UniformTypeIdentifiers

public struct ContentExtractionService: Sendable {
    private let extractors: [any FileContentExtractor]
    private let scheduleExtraction: @Sendable (@escaping @Sendable () -> Void) -> Void
    private let scheduleTimeout: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void

    public init() {
        self.extractors = [
            PlainTextExtractor(),
            PDFContentExtractor(),
            ImageOCRExtractor(),
            RichTextExtractor(),
            OfficeOpenXMLExtractor(),
            MetadataFallbackExtractor(),
        ]
        self.scheduleExtraction = { work in
            Thread.detachNewThread {
                autoreleasepool {
                    work()
                }
            }
        }
        self.scheduleTimeout = { seconds, timeout in
            Thread.detachNewThread {
                Thread.sleep(forTimeInterval: max(0, seconds))
                autoreleasepool {
                    timeout()
                }
            }
        }
    }

    init(
        extractors: [any FileContentExtractor],
        scheduleExtraction: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void,
        scheduleTimeout: @escaping @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void
    ) {
        self.extractors = extractors
        self.scheduleExtraction = scheduleExtraction
        self.scheduleTimeout = scheduleTimeout
    }

    public func extract(fileURL: URL, policy: IndexingPolicy) async -> FileExtractionResult {
        let ext = fileURL.pathExtension.lowercased()
        let contentType = ext.isEmpty ? nil : UTType(filenameExtension: ext)
        let extractor = extractors.first(where: { $0.canHandle(fileURL: fileURL, contentType: contentType) }) ?? MetadataFallbackExtractor()
        let timeoutSeconds = max(0.2, policy.maxExtractionSecondsPerFile)
        let timeoutResult = timeoutFallbackResult(fileURL: fileURL, format: extractor.name)
        let winnerGate = CompletionGate()

        return await withCheckedContinuation { continuation in
            scheduleExtraction {
                let result = performExtraction(
                    extractor: extractor,
                    fileURL: fileURL,
                    contentType: contentType,
                    policy: policy
                )
                winnerGate.resumeOnce {
                    continuation.resume(returning: result)
                }
            }

            scheduleTimeout(timeoutSeconds) {
                winnerGate.resumeOnce {
                    continuation.resume(returning: timeoutResult)
                }
            }
        }
    }
}
