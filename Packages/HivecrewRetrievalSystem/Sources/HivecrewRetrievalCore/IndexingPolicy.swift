import Foundation
import UniformTypeIdentifiers

public struct IndexingPolicy: Sendable, Codable {
    public let allowlistRoots: [String]
    public let excludes: [String]
    public let allowedFileExtensions: Set<String>
    public let nonSearchableFileExtensions: Set<String>
    public let skipUnknownMime: Bool
    public let firstPassFileSizeCapBytes: Int64
    public let hardFileSizeCapBytes: Int64
    public let maxChunksPerDocument: Int
    public let maxExtractedCharactersPerDocument: Int
    public let maxPDFPagesToOCR: Int
    public let maxImagePixelCountForOCR: Int
    public let maxImageDimensionForOCR: Int
    public let maxExtractionSecondsPerFile: TimeInterval
    public let stage1RecentCutoffDays: Int
    public let quietWindowSeconds: TimeInterval

    public init(
        allowlistRoots: [String],
        excludes: [String],
        allowedFileExtensions: Set<String>,
        nonSearchableFileExtensions: Set<String> = [],
        skipUnknownMime: Bool = true,
        firstPassFileSizeCapBytes: Int64 = 1_500_000,
        hardFileSizeCapBytes: Int64 = 20_000_000,
        maxChunksPerDocument: Int = 48,
        maxExtractedCharactersPerDocument: Int = 180_000,
        maxPDFPagesToOCR: Int = 24,
        maxImagePixelCountForOCR: Int = 24_000_000,
        maxImageDimensionForOCR: Int = 6_000,
        maxExtractionSecondsPerFile: TimeInterval = 8,
        stage1RecentCutoffDays: Int = 30,
        quietWindowSeconds: TimeInterval = 20
    ) {
        self.allowlistRoots = allowlistRoots
        self.excludes = excludes
        self.allowedFileExtensions = allowedFileExtensions
        self.nonSearchableFileExtensions = nonSearchableFileExtensions
        self.skipUnknownMime = skipUnknownMime
        self.firstPassFileSizeCapBytes = firstPassFileSizeCapBytes
        self.hardFileSizeCapBytes = hardFileSizeCapBytes
        self.maxChunksPerDocument = maxChunksPerDocument
        self.maxExtractedCharactersPerDocument = maxExtractedCharactersPerDocument
        self.maxPDFPagesToOCR = maxPDFPagesToOCR
        self.maxImagePixelCountForOCR = maxImagePixelCountForOCR
        self.maxImageDimensionForOCR = maxImageDimensionForOCR
        self.maxExtractionSecondsPerFile = maxExtractionSecondsPerFile
        self.stage1RecentCutoffDays = stage1RecentCutoffDays
        self.quietWindowSeconds = quietWindowSeconds
    }

    public static func preset(profile: String, startupAllowlistRoots: [String]) -> IndexingPolicy {
        let commonDocumentFormats: Set<String> = [
            "md", "txt", "rtf", "rtfd", "html", "htm", "pdf",
            "json", "yaml", "yml", "toml", "csv", "tsv", "sql", "xml", "eml", "ics",
            "docx", "pptx", "xlsx", "pages",
            "png", "jpg", "jpeg", "heic", "tiff", "tif", "gif", "webp", "bmp",
        ]
        let developerFormats: Set<String> = [
            "swift", "kt", "js", "ts", "tsx", "jsx", "py", "go", "rs", "rb",
            "java", "c", "cpp", "h", "hpp", "m", "mm", "sh", "zsh", "bash", "ini", "conf", "log",
        ]
        // Keep these indexed for context/intelligence and stats, but suppress them from retrieval ranking.
        let structuredButNonSearchableFormats: Set<String> = [
            "json", "jsonl", "ndjson",
            "yaml", "yml", "toml",
            "sql",
            "csv", "tsv",
            "xml", "plist", "pbxproj", "xcconfig",
            "ini", "conf", "env", "properties",
        ]
        let baseRoots = startupAllowlistRoots.isEmpty
            ? [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents").path]
            : startupAllowlistRoots
        switch profile.lowercased() {
        case "developer":
            return IndexingPolicy(
                allowlistRoots: baseRoots,
                excludes: [".git", "node_modules", "dist", "build", ".build", ".cache", "DerivedData", "Library/Caches", ".swiftpm"],
                allowedFileExtensions: commonDocumentFormats.union(developerFormats),
                nonSearchableFileExtensions: structuredButNonSearchableFormats,
                firstPassFileSizeCapBytes: 2_500_000,
                hardFileSizeCapBytes: 30_000_000,
                maxChunksPerDocument: 80,
                maxExtractedCharactersPerDocument: 240_000,
                maxPDFPagesToOCR: 36,
                maxImagePixelCountForOCR: 30_000_000,
                maxImageDimensionForOCR: 7_000,
                maxExtractionSecondsPerFile: 10,
                stage1RecentCutoffDays: 45
            )
        case "personal":
            return IndexingPolicy(
                allowlistRoots: baseRoots,
                excludes: [".git", "node_modules", ".build", ".cache", "Library/Caches", "Movies", "Pictures"],
                allowedFileExtensions: commonDocumentFormats,
                nonSearchableFileExtensions: structuredButNonSearchableFormats,
                firstPassFileSizeCapBytes: 1_000_000,
                hardFileSizeCapBytes: 10_000_000,
                maxChunksPerDocument: 36,
                maxExtractedCharactersPerDocument: 120_000,
                maxPDFPagesToOCR: 18,
                maxImagePixelCountForOCR: 20_000_000,
                maxImageDimensionForOCR: 5_500,
                maxExtractionSecondsPerFile: 8,
                stage1RecentCutoffDays: 21
            )
        default:
            return IndexingPolicy(
                allowlistRoots: baseRoots,
                excludes: [".git", "node_modules", "dist", "build", ".build", ".cache", "DerivedData", "Library/Caches", "Library/Developer"],
                allowedFileExtensions: commonDocumentFormats.union(["swift", "js", "ts"]),
                nonSearchableFileExtensions: structuredButNonSearchableFormats,
                firstPassFileSizeCapBytes: 1_500_000,
                hardFileSizeCapBytes: 20_000_000,
                maxChunksPerDocument: 48,
                maxExtractedCharactersPerDocument: 180_000,
                maxPDFPagesToOCR: 24,
                maxImagePixelCountForOCR: 24_000_000,
                maxImageDimensionForOCR: 6_000,
                maxExtractionSecondsPerFile: 8,
                stage1RecentCutoffDays: 30
            )
        }
    }

    public func evaluate(fileURL: URL, fileSize: Int64, modifiedAt: Date) -> IndexEvaluation {
        let path = canonicalPath(fileURL.path)
        let normalized = path.lowercased()
        let ext = fileURL.pathExtension.lowercased()
        let contentType = ext.isEmpty ? nil : UTType(filenameExtension: ext)
        for root in allowlistRoots {
            let canonicalRoot = canonicalPath(root)
            guard path == canonicalRoot || path.hasPrefix(canonicalRoot + "/") else {
                continue
            }
            for excluded in excludes where normalized.contains("/\(excluded.lowercased())/") || normalized.hasSuffix("/\(excluded.lowercased())") {
                return .skip(reason: "excluded_path")
            }
            if ext.isEmpty || !allowedFileExtensions.contains(ext) {
                return .skip(reason: "unsupported_file_type")
            }
            if skipUnknownMime && contentType == nil {
                return .skip(reason: "unknown_content_type")
            }
            if fileSize > hardFileSizeCapBytes {
                return .skip(reason: "hard_size_cap")
            }
            if fileSize > firstPassFileSizeCapBytes {
                return .deferred(reason: "deferred_large_file")
            }
            if looksGenerated(path: path) {
                return .skip(reason: "generated_or_minified")
            }
            if isRecent(modifiedAt: modifiedAt) {
                return .index(partition: "hot")
            }
            return .index(partition: "warm")
        }
        return .skip(reason: "outside_allowlist")
    }

    private func looksGenerated(path: String) -> Bool {
        let lower = path.lowercased()
        return lower.contains(".min.") || lower.contains("generated") || lower.contains("bundle.js")
    }

    private func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func isRecent(modifiedAt: Date) -> Bool {
        let cutoff = Calendar.current.date(byAdding: .day, value: -stage1RecentCutoffDays, to: Date()) ?? Date.distantPast
        return modifiedAt >= cutoff
    }
}
