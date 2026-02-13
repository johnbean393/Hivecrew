import AppKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision
import ZIPFoundation

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
        let timeoutResult = FileExtractionResult(
            content: nil,
            telemetry: ExtractionTelemetry(
                outcome: .failed,
                usedOCR: false,
                format: extractor.name,
                detail: "timeout"
            )
        )
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

private func performExtraction(
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
        let outcome: ExtractionOutcomeKind
        if body.isEmpty {
            outcome = normalized.metadata.isEmpty ? .unsupported : .partial
        } else if normalized.warnings.isEmpty {
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

private final class CompletionGate: @unchecked Sendable {
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

private struct PlainTextExtractor: FileContentExtractor {
    let name = "plain_text"

    private static let handledExtensions: Set<String> = [
        "txt", "md", "markdown", "json", "yaml", "yml", "toml", "csv", "tsv", "sql", "xml",
        "swift", "kt", "js", "ts", "tsx", "jsx", "py", "go", "rs", "rb", "java", "c", "cpp",
        "h", "hpp", "m", "mm", "sh", "zsh", "bash", "eml", "ics", "log", "ini", "conf"
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

private struct PDFContentExtractor: FileContentExtractor {
    let name = "pdf"

    func canHandle(fileURL: URL, contentType: UTType?) -> Bool {
        fileURL.pathExtension.lowercased() == "pdf" || contentType?.conforms(to: .pdf) == true
    }

    func extract(fileURL: URL, contentType _: UTType?, policy: IndexingPolicy) throws -> ExtractedContent? {
        guard let document = PDFDocument(url: fileURL) else {
            return nil
        }

        var chunks: [String] = []
        var warnings: [String] = []
        var usedOCR = false
        var remainingOCRBudget = policy.maxPDFPagesToOCR

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty {
                chunks.append(text)
                continue
            }
            guard remainingOCRBudget > 0 else {
                warnings.append("ocr_page_budget_reached")
                continue
            }
            remainingOCRBudget -= 1
            usedOCR = true
            if let ocrText = Self.performOCR(on: page, policy: policy), !ocrText.isEmpty {
                chunks.append(ocrText)
            } else {
                warnings.append("pdf_page_ocr_empty")
            }
        }

        var metadata = fileMetadata(fileURL: fileURL)
        metadata["pageCount"] = "\(document.pageCount)"
        if let attrs = document.documentAttributes {
            if let title = attrs[PDFDocumentAttribute.titleAttribute] as? String, !title.isEmpty {
                metadata["pdfTitle"] = title
            }
            if let author = attrs[PDFDocumentAttribute.authorAttribute] as? String, !author.isEmpty {
                metadata["pdfAuthor"] = author
            }
            if let subject = attrs[PDFDocumentAttribute.subjectAttribute] as? String, !subject.isEmpty {
                metadata["pdfSubject"] = subject
            }
        }

        let body = chunks.joined(separator: "\n\n")
        return ExtractedContent(
            text: body,
            title: metadata["pdfTitle"] ?? fileURL.lastPathComponent,
            metadata: metadata,
            warnings: warnings,
            wasOCRUsed: usedOCR
        )
    }

    private static func performOCR(on page: PDFPage, policy: IndexingPolicy) -> String? {
        let size = CGSize(
            width: min(policy.maxImageDimensionForOCR, 2_048),
            height: min(policy.maxImageDimensionForOCR, 2_048)
        )
        let thumbnail = page.thumbnail(of: size, for: .mediaBox)
        guard let cgImage = thumbnail.hcCGImage else {
            return nil
        }
        return OCR.extractText(
            from: cgImage,
            recognitionLanguages: ["en-US"]
        )
    }
}

private struct ImageOCRExtractor: FileContentExtractor {
    let name = "image_ocr"

    private static let extensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "tif", "gif", "webp", "bmp"]

    func canHandle(fileURL: URL, contentType: UTType?) -> Bool {
        let ext = fileURL.pathExtension.lowercased()
        if Self.extensions.contains(ext) {
            return true
        }
        return contentType?.conforms(to: .image) == true
    }

    func extract(fileURL: URL, contentType _: UTType?, policy: IndexingPolicy) throws -> ExtractedContent? {
        guard let imageSource = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
            return nil
        }
        let properties = (CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]) ?? [:]
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let pixels = max(0, width) * max(0, height)

        var metadata = fileMetadata(fileURL: fileURL)
        metadata["width"] = "\(width)"
        metadata["height"] = "\(height)"

        var warnings: [String] = []
        let shouldRunOCR = width > 0
            && height > 0
            && pixels <= policy.maxImagePixelCountForOCR
            && width <= policy.maxImageDimensionForOCR
            && height <= policy.maxImageDimensionForOCR

        if !shouldRunOCR {
            warnings.append("image_ocr_skipped_size_limit")
            return ExtractedContent(
                text: "",
                title: fileURL.lastPathComponent,
                metadata: metadata,
                warnings: warnings,
                wasOCRUsed: false
            )
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: policy.maxImageDimensionForOCR,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            return ExtractedContent(
                text: "",
                title: fileURL.lastPathComponent,
                metadata: metadata,
                warnings: ["image_decode_failed"],
                wasOCRUsed: false
            )
        }
        let text = OCR.extractText(from: cgImage, recognitionLanguages: ["en-US"]) ?? ""
        if text.isEmpty {
            warnings.append("image_ocr_empty")
        }
        return ExtractedContent(
            text: text,
            title: fileURL.lastPathComponent,
            metadata: metadata,
            warnings: warnings,
            wasOCRUsed: true
        )
    }
}

private struct RichTextExtractor: FileContentExtractor {
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

private struct OfficeOpenXMLExtractor: FileContentExtractor {
    let name = "office_openxml"

    private static let extensions: Set<String> = ["docx", "pptx", "xlsx"]

    func canHandle(fileURL: URL, contentType _: UTType?) -> Bool {
        Self.extensions.contains(fileURL.pathExtension.lowercased())
    }

    func extract(fileURL: URL, contentType _: UTType?, policy _: IndexingPolicy) throws -> ExtractedContent? {
        let archive = try Archive(url: fileURL, accessMode: .read)

        let ext = fileURL.pathExtension.lowercased()
        let paths = extractionPaths(for: ext, archive: archive)
        if paths.isEmpty {
            return ExtractedContent(
                text: "",
                title: fileURL.lastPathComponent,
                metadata: fileMetadata(fileURL: fileURL),
                warnings: ["openxml_paths_missing"]
            )
        }

        var chunks: [String] = []
        for path in paths {
            guard let entry = archive[path], let xmlData = try entryData(for: entry, archive: archive) else {
                continue
            }
            let extracted = XMLTextExtractor.extractText(from: xmlData)
            if !extracted.isEmpty {
                chunks.append(extracted)
            }
        }

        var metadata = fileMetadata(fileURL: fileURL)
        metadata["openXmlPartCount"] = "\(paths.count)"
        let warnings = chunks.isEmpty ? ["openxml_empty_text"] : []
        return ExtractedContent(
            text: chunks.joined(separator: "\n\n"),
            title: fileURL.lastPathComponent,
            metadata: metadata,
            warnings: warnings
        )
    }

    private func extractionPaths(for ext: String, archive: Archive) -> [String] {
        let archivePaths = archive.map(\.path)
        switch ext {
        case "docx":
            let sorted = archivePaths
                .filter { $0.hasPrefix("word/") && $0.hasSuffix(".xml") }
                .sorted()
            if sorted.contains("word/document.xml") {
                return ["word/document.xml"] + sorted.filter { $0 != "word/document.xml" }
            }
            return sorted
        case "pptx":
            return archivePaths
                .filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
                .sorted(by: naturalPathOrder)
        case "xlsx":
            var candidates: [String] = []
            if archivePaths.contains("xl/sharedStrings.xml") {
                candidates.append("xl/sharedStrings.xml")
            }
            candidates += archivePaths
                .filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }
                .sorted(by: naturalPathOrder)
            return candidates
        default:
            return []
        }
    }

    private func naturalPathOrder(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }

    private func entryData(for entry: Entry, archive: Archive) throws -> Data? {
        var data = Data()
        _ = try archive.extract(entry) { chunk in
            data.append(chunk)
        }
        return data
    }
}

private struct MetadataFallbackExtractor: FileContentExtractor {
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

private enum OCR {
    static func extractText(from cgImage: CGImage, recognitionLanguages: [String]) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = recognitionLanguages

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            let lines = request.results?
                .compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty } ?? []
            return lines.joined(separator: "\n")
        } catch {
            return nil
        }
    }
}

private enum XMLTextExtractor {
    static func extractText(from xmlData: Data) -> String {
        let parserDelegate = XMLTextCollector()
        let parser = XMLParser(data: xmlData)
        parser.delegate = parserDelegate
        parser.shouldResolveExternalEntities = false
        _ = parser.parse()
        let raw = parserDelegate.fragments.joined(separator: " ")
        return raw
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private final class XMLTextCollector: NSObject, XMLParserDelegate {
        var fragments: [String] = []
        private var capturingTextNode = false

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI _: String?,
            qualifiedName _: String?,
            attributes _: [String: String] = [:]
        ) {
            let lower = elementName.lowercased()
            if lower == "t" || lower.hasSuffix(":t") {
                capturingTextNode = true
                return
            }
            if lower == "br" || lower.hasSuffix(":br") || lower == "p" || lower.hasSuffix(":p") {
                fragments.append("\n")
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard capturingTextNode else { return }
            fragments.append(string)
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI _: String?,
            qualifiedName _: String?
        ) {
            let lower = elementName.lowercased()
            if lower == "t" || lower.hasSuffix(":t") {
                capturingTextNode = false
                fragments.append(" ")
            }
            if lower == "p" || lower.hasSuffix(":p") || lower == "row" || lower.hasSuffix(":row") {
                fragments.append("\n")
            }
        }
    }
}

private func fileMetadata(fileURL: URL) -> [String: String] {
    let values = try? fileURL.resourceValues(forKeys: [
        .creationDateKey,
        .contentModificationDateKey,
        .fileSizeKey,
        .contentTypeKey,
        .localizedNameKey,
        .isDirectoryKey,
    ])
    var metadata: [String: String] = [:]
    metadata["path"] = fileURL.path
    metadata["name"] = values?.localizedName ?? fileURL.lastPathComponent
    metadata["extension"] = fileURL.pathExtension.lowercased()
    if let type = values?.contentType?.identifier {
        metadata["uti"] = type
    }
    if let size = values?.fileSize {
        metadata["sizeBytes"] = "\(size)"
    }
    if let createdAt = values?.creationDate {
        metadata["createdAt"] = ISO8601DateFormatter().string(from: createdAt)
    }
    if let modifiedAt = values?.contentModificationDate {
        metadata["modifiedAt"] = ISO8601DateFormatter().string(from: modifiedAt)
    }
    if values?.isDirectory == true {
        metadata["isDirectory"] = "true"
    }
    return metadata
}

private extension NSImage {
    var hcCGImage: CGImage? {
        var rect = NSRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
