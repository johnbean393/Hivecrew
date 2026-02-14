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
        let codeFileFormats: Set<String> = [
            "swift", "kt", "js", "ts", "tsx", "jsx", "py", "go", "rs", "rb",
            "java", "c", "cpp", "h", "hpp", "m", "mm", "sh", "zsh", "bash",
            "php", "cs", "scala", "r", "lua", "pl",
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
        // Code is skipped at ingestion now, but keep code extensions non-searchable so old indexed rows stay hidden.
        let nonSearchableFormats = structuredButNonSearchableFormats.union(codeFileFormats)
        let buildOutputExcludes: [String] = [
            ".build", "build", "dist", "out", "target", "coverage",
            ".gradle", ".next", ".nuxt", ".svelte-kit", ".angular", ".turbo", ".parcel-cache", ".vite", ".webpack-cache",
            "cmake-build-*", "bazel-*",
            ".pytest_cache", ".mypy_cache", ".ruff_cache", ".tox", ".nox",
        ]
        let dependencyExcludes: [String] = [
            "site-packages", "dist-packages", "__pycache__", ".venv", "venv",
            "Pods", "Carthage", "Frameworks", "checkouts", "vendor", "third_party", "third-party",
            "bower_components", ".pnpm-store", ".yarn", ".m2", ".ivy2",
        ]
        // Do not default to protected folders (Documents/Desktop). Those trigger
        // recurring TCC prompts for the standalone daemon across restarts/builds.
        // Indexing starts only from explicitly configured allowlist roots.
        let baseRoots = startupAllowlistRoots.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        switch profile.lowercased() {
        case "developer":
            return IndexingPolicy(
                allowlistRoots: baseRoots,
                excludes: [".git", "node_modules", ".cache", "DerivedData", "Library/Caches", "Library/Developer", ".swiftpm"] + buildOutputExcludes + dependencyExcludes,
                allowedFileExtensions: commonDocumentFormats,
                nonSearchableFileExtensions: nonSearchableFormats,
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
                excludes: [".git", "node_modules", ".cache", "Library/Caches", "Movies", "Pictures"] + buildOutputExcludes + dependencyExcludes,
                allowedFileExtensions: commonDocumentFormats,
                nonSearchableFileExtensions: nonSearchableFormats,
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
                excludes: [".git", "node_modules", ".cache", "DerivedData", "Library/Caches", "Library/Developer"] + buildOutputExcludes + dependencyExcludes,
                allowedFileExtensions: commonDocumentFormats,
                nonSearchableFileExtensions: nonSearchableFormats,
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
        for root in allowlistRoots {
            let canonicalRoot = canonicalPath(root)
            guard path == canonicalRoot || path.hasPrefix(canonicalRoot + "/") else {
                continue
            }
            if shouldSkipPath(path) {
                return .skip(reason: "excluded_path")
            }
            if let reason = fileTypeSkipReason(fileURL: fileURL) {
                return .skip(reason: reason)
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

    public func shouldSkipPath(_ rawPath: String) -> Bool {
        let normalized = canonicalPath(rawPath).lowercased()
        let components = normalized.split(separator: "/")
        for excluded in excludes {
            let token = excluded.lowercased()
            if token.contains("/") {
                if normalized.contains("/\(token)/") || normalized.hasSuffix("/\(token)") {
                    return true
                }
                continue
            }
            if token.contains("*") {
                let parts = token.split(separator: "*", maxSplits: 1, omittingEmptySubsequences: false)
                let prefix = parts.count > 0 ? String(parts[0]) : ""
                let suffix = parts.count > 1 ? String(parts[1]) : ""
                if components.contains(where: { component in
                    (prefix.isEmpty || component.hasPrefix(prefix)) &&
                        (suffix.isEmpty || component.hasSuffix(suffix))
                }) {
                    return true
                }
                continue
            }
            if components.contains(where: { $0 == token }) {
                return true
            }
            // Build systems create many directories like "Configuration.build";
            // treat any "*.build" path component as excluded.
            if token == ".build", components.contains(where: { $0.hasSuffix(".build") }) {
                return true
            }
        }
        return false
    }

    public func shouldAttemptFileIngestion(fileURL: URL) -> Bool {
        if shouldSkipPath(fileURL.path) {
            return false
        }
        return fileTypeSkipReason(fileURL: fileURL) == nil
    }

    private func fileTypeSkipReason(fileURL: URL) -> String? {
        let ext = fileURL.pathExtension.lowercased()
        let contentType = ext.isEmpty ? nil : UTType(filenameExtension: ext)
        if ext.isEmpty || !allowedFileExtensions.contains(ext) {
            return "unsupported_file_type"
        }
        if skipUnknownMime && contentType == nil {
            return "unknown_content_type"
        }
        return nil
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
