import Foundation
import UniformTypeIdentifiers
import ZIPFoundation

struct OfficeOpenXMLExtractor: FileContentExtractor {
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
