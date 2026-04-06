//
//  HostFileReader.swift
//  Hivecrew
//
//  Shared host-side file reading utility. Supports PDF, Office documents,
//  RTF, plist, images, and plain text files. Used by both PlanningTools
//  and voice orchestrator tools.
//

import Foundation
import AppKit
import PDFKit

// MARK: - Read Result

struct HostFileReadResult {
    let text: String
    let imageBase64: String?
    let imageMimeType: String?

    var hasImage: Bool { imageBase64 != nil }

    static func text(_ content: String) -> HostFileReadResult {
        HostFileReadResult(text: content, imageBase64: nil, imageMimeType: nil)
    }

    static func image(description: String, base64: String, mimeType: String) -> HostFileReadResult {
        HostFileReadResult(text: description, imageBase64: base64, imageMimeType: mimeType)
    }
}

// MARK: - Host File Reader

enum HostFileReader {

    /// Read the full contents of a file at the given URL.
    static func read(at url: URL) async throws -> HostFileReadResult {
        let ext = url.pathExtension.lowercased()

        switch ext {
        case "pdf":
            return .text(try extractTextFromPDF(at: url))
        case "docx":
            return .text(try extractTextFromOfficeDocument(at: url, type: .docx))
        case "xlsx":
            return .text(try extractTextFromOfficeDocument(at: url, type: .xlsx))
        case "pptx":
            return .text(try extractTextFromOfficeDocument(at: url, type: .pptx))
        case "rtf":
            return .text(try extractTextFromRTF(at: url))
        case "plist":
            return .text(try extractTextFromPlist(at: url))
        case "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "bmp":
            return try readImage(at: url)
        default:
            return .text(try readTextFile(at: url))
        }
    }

    /// Read a file and return only the sections matching `query` (case-insensitive).
    /// Falls back to the full read for non-text content (images).
    static func readAndSearch(at url: URL, query: String) async throws -> HostFileReadResult {
        let result = try await read(at: url)

        guard !result.hasImage else { return result }

        let lines = result.text.components(separatedBy: .newlines)
        let lower = query.lowercased()
        var matched: [String] = []
        let contextRadius = 2

        for (i, line) in lines.enumerated() where line.lowercased().contains(lower) {
            let start = max(0, i - contextRadius)
            let end = min(lines.count - 1, i + contextRadius)
            let section = lines[start...end].joined(separator: "\n")
            if matched.last != section {
                matched.append(section)
            }
        }

        if matched.isEmpty {
            return .text("No matches for \"\(query)\" in \(url.lastPathComponent).")
        }

        let header = "Found \(matched.count) match(es) for \"\(query)\" in \(url.lastPathComponent):\n"
        return .text(header + matched.joined(separator: "\n---\n"))
    }

    // MARK: - Text File

    static func readTextFile(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)

        let encodings: [String.Encoding] = [
            .utf8, .utf16, .utf16LittleEndian, .utf16BigEndian,
            .isoLatin1, .ascii, .windowsCP1252, .macOSRoman
        ]

        for encoding in encodings {
            if let contents = String(data: data, encoding: encoding) {
                if contents.count > 50_000 {
                    return String(contents.prefix(50_000)) + "\n\n[... truncated, file too long ...]"
                }
                return contents
            }
        }

        if data.count <= 1024 {
            return "[Binary file - \(data.count) bytes]"
        } else {
            return "[Binary file - \(data.count) bytes, content not displayed]"
        }
    }

    // MARK: - PDF

    static func extractTextFromPDF(at url: URL) throws -> String {
        guard let document = PDFDocument(url: url) else {
            throw HostFileReaderError.readFailed("Failed to open PDF document")
        }

        var text = ""
        let maxPages = min(document.pageCount, 50)

        for pageIndex in 0..<maxPages {
            if let page = document.page(at: pageIndex),
               let pageText = page.string {
                if !text.isEmpty {
                    text += "\n\n--- Page \(pageIndex + 1) ---\n\n"
                }
                text += pageText
            }
        }

        if document.pageCount > maxPages {
            text += "\n\n[... \(document.pageCount - maxPages) more pages not shown ...]"
        }

        if text.isEmpty {
            return "[PDF contains no extractable text - may be scanned/image-based]"
        }

        return text
    }

    // MARK: - RTF

    static func extractTextFromRTF(at url: URL) throws -> String {
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.rtf
        ]
        let attributedString = try NSAttributedString(url: url, options: options, documentAttributes: nil)
        return attributedString.string
    }

    // MARK: - Plist

    static func extractTextFromPlist(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let plistObject = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)

        if JSONSerialization.isValidJSONObject(plistObject) {
            let jsonData = try JSONSerialization.data(withJSONObject: plistObject, options: [.prettyPrinted, .sortedKeys])
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                return jsonString
            }
        }

        return String(describing: plistObject)
    }

    // MARK: - Image

    static func readImage(at url: URL) throws -> HostFileReadResult {
        let imageData = try Data(contentsOf: url)

        guard let image = NSImage(data: imageData) else {
            throw HostFileReaderError.readFailed("Failed to load image")
        }

        guard let bitmapRep = image.representations.first else {
            throw HostFileReaderError.readFailed("Failed to get image representation")
        }

        let width = bitmapRep.pixelsWide > 0 ? bitmapRep.pixelsWide : Int(image.size.width)
        let height = bitmapRep.pixelsHigh > 0 ? bitmapRep.pixelsHigh : Int(image.size.height)

        let filename = url.lastPathComponent
        let fileSizeStr = ByteCountFormatter.string(fromByteCount: Int64(imageData.count), countStyle: .file)

        let originalMimeType = mimeTypeForExtension(url.pathExtension)
        let base64Data = imageData.base64EncodedString()

        let (finalBase64, finalMimeType): (String, String)
        if let downscaled = ImageDownscaler.downscale(
            base64Data: base64Data,
            mimeType: originalMimeType,
            to: .medium
        ) {
            finalBase64 = downscaled.data
            finalMimeType = downscaled.mimeType
        } else {
            finalBase64 = base64Data
            finalMimeType = originalMimeType
        }

        let description = """
            [Image: \(filename)]
            Dimensions: \(width) x \(height) pixels
            File size: \(fileSizeStr)
            Format: \(url.pathExtension.uppercased())
            """

        return .image(description: description, base64: finalBase64, mimeType: finalMimeType)
    }

    static func mimeTypeForExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic", "heif": return "image/heic"
        case "tiff", "tif": return "image/tiff"
        case "bmp": return "image/bmp"
        default: return "image/jpeg"
        }
    }

    // MARK: - Office Documents

    enum OfficeDocumentType {
        case docx, xlsx, pptx
    }

    static func extractTextFromOfficeDocument(at url: URL, type: OfficeDocumentType) throws -> String {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", url.path, "-d", tempDir.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw HostFileReaderError.readFailed("Failed to extract Office document")
        }

        switch type {
        case .docx: return try extractTextFromDocx(tempDir: tempDir)
        case .xlsx: return try extractTextFromXlsx(tempDir: tempDir)
        case .pptx: return try extractTextFromPptx(tempDir: tempDir)
        }
    }

    private static func extractTextFromDocx(tempDir: URL) throws -> String {
        let documentXML = tempDir.appendingPathComponent("word/document.xml")
        guard FileManager.default.fileExists(atPath: documentXML.path) else {
            throw HostFileReaderError.readFailed("Invalid docx structure")
        }
        let xmlData = try Data(contentsOf: documentXML)
        return extractTextFromXML(xmlData, textElements: ["w:t"])
    }

    private static func extractTextFromXlsx(tempDir: URL) throws -> String {
        var allText: [String] = []

        let sharedStringsPath = tempDir.appendingPathComponent("xl/sharedStrings.xml")
        if FileManager.default.fileExists(atPath: sharedStringsPath.path) {
            let xmlData = try Data(contentsOf: sharedStringsPath)
            let sharedStrings = extractTextFromXML(xmlData, textElements: ["t"])
            if !sharedStrings.isEmpty {
                allText.append("--- Shared Strings ---\n\(sharedStrings)")
            }
        }

        let sheetsDir = tempDir.appendingPathComponent("xl/worksheets")
        if let sheetFiles = try? FileManager.default.contentsOfDirectory(atPath: sheetsDir.path) {
            for sheetFile in sheetFiles.sorted() where sheetFile.hasSuffix(".xml") {
                let sheetPath = sheetsDir.appendingPathComponent(sheetFile)
                let xmlData = try Data(contentsOf: sheetPath)
                let sheetText = extractTextFromXML(xmlData, textElements: ["v", "t"])
                if !sheetText.isEmpty {
                    allText.append("--- \(sheetFile) ---\n\(sheetText)")
                }
            }
        }

        return allText.joined(separator: "\n\n")
    }

    private static func extractTextFromPptx(tempDir: URL) throws -> String {
        var allText: [String] = []

        let slidesDir = tempDir.appendingPathComponent("ppt/slides")
        if let slideFiles = try? FileManager.default.contentsOfDirectory(atPath: slidesDir.path) {
            for slideFile in slideFiles.sorted() where slideFile.hasSuffix(".xml") {
                let slidePath = slidesDir.appendingPathComponent(slideFile)
                let xmlData = try Data(contentsOf: slidePath)
                let slideText = extractTextFromXML(xmlData, textElements: ["a:t"])
                if !slideText.isEmpty {
                    allText.append("--- \(slideFile) ---\n\(slideText)")
                }
            }
        }

        return allText.joined(separator: "\n\n")
    }

    static func extractTextFromXML(_ data: Data, textElements: [String]) -> String {
        guard let xmlString = String(data: data, encoding: .utf8) else { return "" }

        var texts: [String] = []

        for element in textElements {
            let pattern = "<\(element)(?:\\s[^>]*)?>([^<]*)</\(element)>"
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let range = NSRange(xmlString.startIndex..., in: xmlString)
                let matches = regex.matches(in: xmlString, options: [], range: range)
                for match in matches {
                    if let textRange = Range(match.range(at: 1), in: xmlString) {
                        let text = String(xmlString[textRange])
                        if !text.isEmpty {
                            texts.append(text)
                        }
                    }
                }
            }
        }

        return texts.joined(separator: " ")
    }
}

// MARK: - Error

enum HostFileReaderError: Error, LocalizedError {
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .readFailed(let message):
            return "Failed to read file: \(message)"
        }
    }
}
