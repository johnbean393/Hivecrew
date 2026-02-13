import AppKit
import Foundation
import Vision

enum OCR {
    static func extractText(from cgImage: CGImage, recognitionLanguages: [String]) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
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

enum XMLTextExtractor {
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

func fileMetadata(fileURL: URL) -> [String: String] {
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

extension NSImage {
    var hcCGImage: CGImage? {
        var rect = NSRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
