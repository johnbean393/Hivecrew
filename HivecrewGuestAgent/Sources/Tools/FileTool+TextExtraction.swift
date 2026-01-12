//
//  FileTool+TextExtraction.swift
//  HivecrewGuestAgent
//
//  Text extraction methods for various file formats
//

import Foundation
import AppKit
import PDFKit
import HivecrewAgentProtocol

// MARK: - PDF Extraction

extension FileTool {
    
    /// Extract text from a PDF file using PDFKit
    func extractTextFromPDF(at path: String) throws -> String {
        let url = URL(fileURLWithPath: path)
        
        guard let document = PDFDocument(url: url) else {
            throw AgentError(code: AgentError.toolExecutionFailed, message: "Failed to open PDF document")
        }
        
        var text = ""
        for pageIndex in 0..<document.pageCount {
            if let page = document.page(at: pageIndex),
               let pageText = page.string {
                if !text.isEmpty {
                    text += "\n\n--- Page \(pageIndex + 1) ---\n\n"
                }
                text += pageText
            }
        }
        
        if text.isEmpty {
            logger.warning("PDF appears to contain no extractable text (may be image-based)")
            return "[PDF contains no extractable text - may be scanned/image-based]"
        }
        
        return text
    }
}

// MARK: - RTF Extraction

extension FileTool {
    
    /// Extract plain text from an RTF file using NSAttributedString
    func extractTextFromRTF(at path: String) throws -> String {
        let url = URL(fileURLWithPath: path)
        
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.rtf
        ]
        
        do {
            let attributedString = try NSAttributedString(url: url, options: options, documentAttributes: nil)
            return attributedString.string
        } catch {
            throw AgentError(code: AgentError.toolExecutionFailed, message: "Failed to read RTF: \(error.localizedDescription)")
        }
    }
}

// MARK: - Office Document Extraction

extension FileTool {
    
    /// Extract text from Office documents (.docx, .xlsx, .pptx)
    /// These are ZIP archives containing XML files
    func extractTextFromOfficeDocument(at path: String, type: FileType.OfficeDocumentType) throws -> String {
        let url = URL(fileURLWithPath: path)
        
        // Create a temporary directory for extraction
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            
            // Use unzip command to extract the archive
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-q", url.path, "-d", tempDir.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            
            try process.run()
            process.waitUntilExit()
            
            guard process.terminationStatus == 0 else {
                throw AgentError(code: AgentError.toolExecutionFailed, message: "Failed to extract Office document")
            }
            
            // Extract text based on document type
            switch type {
            case .docx:
                return try extractTextFromDocx(tempDir: tempDir)
            case .xlsx:
                return try extractTextFromXlsx(tempDir: tempDir)
            case .pptx:
                return try extractTextFromPptx(tempDir: tempDir)
            }
        } catch let error as AgentError {
            throw error
        } catch {
            throw AgentError(code: AgentError.toolExecutionFailed, message: "Failed to process Office document: \(error.localizedDescription)")
        }
    }
    
    /// Extract text from a .docx document
    func extractTextFromDocx(tempDir: URL) throws -> String {
        let documentXML = tempDir.appendingPathComponent("word/document.xml")
        
        guard FileManager.default.fileExists(atPath: documentXML.path) else {
            throw AgentError(code: AgentError.toolExecutionFailed, message: "Invalid docx structure: document.xml not found")
        }
        
        let xmlData = try Data(contentsOf: documentXML)
        return extractTextFromXML(xmlData, textElements: ["w:t"])
    }
    
    /// Extract text from a .xlsx document
    func extractTextFromXlsx(tempDir: URL) throws -> String {
        var allText: [String] = []
        
        // Read shared strings (contains cell text)
        let sharedStringsPath = tempDir.appendingPathComponent("xl/sharedStrings.xml")
        if FileManager.default.fileExists(atPath: sharedStringsPath.path) {
            let xmlData = try Data(contentsOf: sharedStringsPath)
            let sharedStrings = extractTextFromXML(xmlData, textElements: ["t"])
            if !sharedStrings.isEmpty {
                allText.append("--- Shared Strings ---\n\(sharedStrings)")
            }
        }
        
        // Read each sheet
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
    
    /// Extract text from a .pptx document
    func extractTextFromPptx(tempDir: URL) throws -> String {
        var allText: [String] = []
        
        // Read each slide
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
    
    /// Extract text content from XML data by finding specific elements
    func extractTextFromXML(_ data: Data, textElements: [String]) -> String {
        // Simple regex-based extraction for text elements
        guard let xmlString = String(data: data, encoding: .utf8) else { return "" }
        
        var texts: [String] = []
        
        for element in textElements {
            // Match <element>text</element> or <element ...>text</element>
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

// MARK: - Plist Extraction

extension FileTool {
    
    /// Read and convert a plist file to readable text
    func extractTextFromPlist(at path: String) throws -> String {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        
        // Try to deserialize the plist
        let plistObject: Any
        do {
            plistObject = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            throw AgentError(code: AgentError.toolExecutionFailed, message: "Failed to parse plist: \(error.localizedDescription)")
        }
        
        // Convert to JSON for readable output
        if JSONSerialization.isValidJSONObject(plistObject) {
            let jsonData = try JSONSerialization.data(withJSONObject: plistObject, options: [.prettyPrinted, .sortedKeys])
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                return jsonString
            }
        }
        
        // Fallback to description
        return String(describing: plistObject)
    }
}

// MARK: - Image Reading

extension FileTool {
    
    /// Read an image file and return as base64 with metadata
    func readImageAsBase64(at path: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        
        let base64 = data.base64EncodedString()
        
        // Determine MIME type from extension
        let ext = (path as NSString).pathExtension.lowercased()
        let mimeType: String
        switch ext {
        case "png": mimeType = "image/png"
        case "jpg", "jpeg": mimeType = "image/jpeg"
        case "gif": mimeType = "image/gif"
        case "webp": mimeType = "image/webp"
        case "bmp": mimeType = "image/bmp"
        case "tiff", "tif": mimeType = "image/tiff"
        case "heic", "heif": mimeType = "image/heic"
        case "ico": mimeType = "image/x-icon"
        case "svg": mimeType = "image/svg+xml"
        default: mimeType = "application/octet-stream"
        }
        
        // Get image dimensions if possible
        var result: [String: Any] = [
            "contents": base64,
            "fileType": "image",
            "mimeType": mimeType,
            "isBase64": true
        ]
        
        if let image = NSImage(contentsOfFile: path) {
            result["width"] = Int(image.size.width)
            result["height"] = Int(image.size.height)
        }
        
        return result
    }
}

// MARK: - Text Encoding Fallback

extension FileTool {
    
    /// Try to read a file as text with multiple encoding fallbacks
    func readWithEncodingFallback(at path: String) throws -> (contents: String, encoding: String) {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        
        // Try encodings in order of likelihood
        let encodings: [(String.Encoding, String)] = [
            (.utf8, "utf-8"),
            (.utf16, "utf-16"),
            (.utf16LittleEndian, "utf-16-le"),
            (.utf16BigEndian, "utf-16-be"),
            (.isoLatin1, "iso-8859-1"),
            (.ascii, "ascii"),
            (.windowsCP1252, "windows-1252"),
            (.macOSRoman, "macos-roman")
        ]
        
        for (encoding, name) in encodings {
            if let contents = String(data: data, encoding: encoding) {
                logger.log("Successfully read file with encoding: \(name)")
                return (contents, name)
            }
        }
        
        // If all text encodings fail, return hex dump for small files or error for large ones
        if data.count <= 10240 {
            // For small binary files, return a hex representation
            let hexString = data.map { String(format: "%02x", $0) }.joined(separator: " ")
            return ("[Binary data - hex dump]\n\(hexString)", "binary")
        } else {
            throw AgentError(code: AgentError.toolExecutionFailed, message: "File appears to be binary and is too large to display (size: \(data.count) bytes)")
        }
    }
}
