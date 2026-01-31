//
//  PlanningTools.swift
//  Hivecrew
//
//  Host-side tools for the planning agent (no VM required)
//

import Foundation
import AppKit
import PDFKit
import HivecrewLLM

/// Tools available to the planning agent (host-side, no VM)
public struct PlanningTools {
    
    // MARK: - Tool Definitions
    
    /// Tool definition for reading attached files
    public static let readFile = LLMToolDefinition.function(
        name: "read_file",
        description: "Read the contents of an attached file to understand its content for planning. Use this to examine files provided by the user.",
        parameters: [
            "type": "object",
            "properties": [
                "filename": [
                    "type": "string",
                    "description": "The filename to read from the attached files list"
                ]
            ],
            "required": ["filename"]
        ]
    )
    
    /// All tools available to the planning agent
    public static let allTools: [LLMToolDefinition] = [readFile]
    
    // MARK: - Tool Execution
    
    /// Execute a tool call and return the result
    /// - Parameters:
    ///   - toolCall: The tool call from the LLM
    ///   - attachedFiles: Map of filename to host file path
    /// - Returns: The tool result as a string
    public static func executeToolCall(
        _ toolCall: LLMToolCall,
        attachedFiles: [String: URL]
    ) async throws -> String {
        switch toolCall.function.name {
        case "read_file":
            return try await executeReadFile(toolCall, attachedFiles: attachedFiles)
        default:
            return "Unknown tool: \(toolCall.function.name)"
        }
    }
    
    /// Execute the read_file tool
    private static func executeReadFile(
        _ toolCall: LLMToolCall,
        attachedFiles: [String: URL]
    ) async throws -> String {
        let args = try toolCall.function.argumentsDictionary()
        
        guard let filename = args["filename"] as? String else {
            return "Error: Missing required parameter 'filename'"
        }
        
        // Find the file in attached files
        guard let fileURL = attachedFiles[filename] else {
            let availableFiles = attachedFiles.keys.sorted().joined(separator: ", ")
            return "Error: File '\(filename)' not found. Available files: \(availableFiles)"
        }
        
        // Read the file content
        return try await readFileContent(at: fileURL)
    }
    
    /// Read file content with support for various formats
    private static func readFileContent(at url: URL) async throws -> String {
        let fileExtension = url.pathExtension.lowercased()
        
        switch fileExtension {
        // PDF
        case "pdf":
            return try extractTextFromPDF(at: url)
            
        // Office documents
        case "docx":
            return try extractTextFromOfficeDocument(at: url, type: .docx)
        case "xlsx":
            return try extractTextFromOfficeDocument(at: url, type: .xlsx)
        case "pptx":
            return try extractTextFromOfficeDocument(at: url, type: .pptx)
            
        // RTF
        case "rtf":
            return try extractTextFromRTF(at: url)
            
        // Plist
        case "plist":
            return try extractTextFromPlist(at: url)
            
        // Images - return description
        case "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "bmp":
            return try describeImage(at: url)
            
        // Plain text and code files
        default:
            return try readTextFile(at: url)
        }
    }
    
    // MARK: - Text Extraction Methods
    
    /// Read a plain text file with encoding fallbacks
    private static func readTextFile(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        
        // Try encodings in order of likelihood
        let encodings: [String.Encoding] = [
            .utf8, .utf16, .utf16LittleEndian, .utf16BigEndian,
            .isoLatin1, .ascii, .windowsCP1252, .macOSRoman
        ]
        
        for encoding in encodings {
            if let contents = String(data: data, encoding: encoding) {
                // Truncate if too long
                if contents.count > 50000 {
                    return String(contents.prefix(50000)) + "\n\n[... truncated, file too long ...]"
                }
                return contents
            }
        }
        
        // Binary file
        if data.count <= 1024 {
            return "[Binary file - \(data.count) bytes]"
        } else {
            return "[Binary file - \(data.count) bytes, content not displayed]"
        }
    }
    
    /// Extract text from a PDF file
    private static func extractTextFromPDF(at url: URL) throws -> String {
        guard let document = PDFDocument(url: url) else {
            throw PlanningToolError.fileReadFailed("Failed to open PDF document")
        }
        
        var text = ""
        let maxPages = min(document.pageCount, 50) // Limit for planning
        
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
    
    /// Extract text from RTF file
    private static func extractTextFromRTF(at url: URL) throws -> String {
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.rtf
        ]
        
        let attributedString = try NSAttributedString(url: url, options: options, documentAttributes: nil)
        return attributedString.string
    }
    
    /// Extract text from plist file
    private static func extractTextFromPlist(at url: URL) throws -> String {
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
    
    /// Describe an image file (basic metadata for planning)
    private static func describeImage(at url: URL) throws -> String {
        guard let image = NSImage(contentsOf: url) else {
            throw PlanningToolError.fileReadFailed("Failed to load image")
        }
        
        guard let bitmapRep = image.representations.first else {
            throw PlanningToolError.fileReadFailed("Failed to get image representation")
        }
        
        let width = bitmapRep.pixelsWide > 0 ? bitmapRep.pixelsWide : Int(image.size.width)
        let height = bitmapRep.pixelsHigh > 0 ? bitmapRep.pixelsHigh : Int(image.size.height)
        
        let filename = url.lastPathComponent
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let fileSizeStr = ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
        
        return """
        [Image File]
        Filename: \(filename)
        Dimensions: \(width) x \(height) pixels
        File size: \(fileSizeStr)
        Format: \(url.pathExtension.uppercased())
        
        Note: Image content cannot be displayed in text. The agent will have access to view this image during execution.
        """
    }
    
    // MARK: - Office Document Extraction
    
    enum OfficeDocumentType {
        case docx, xlsx, pptx
    }
    
    private static func extractTextFromOfficeDocument(at url: URL, type: OfficeDocumentType) throws -> String {
        // Create a temporary directory for extraction
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        
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
            throw PlanningToolError.fileReadFailed("Failed to extract Office document")
        }
        
        switch type {
        case .docx:
            return try extractTextFromDocx(tempDir: tempDir)
        case .xlsx:
            return try extractTextFromXlsx(tempDir: tempDir)
        case .pptx:
            return try extractTextFromPptx(tempDir: tempDir)
        }
    }
    
    private static func extractTextFromDocx(tempDir: URL) throws -> String {
        let documentXML = tempDir.appendingPathComponent("word/document.xml")
        
        guard FileManager.default.fileExists(atPath: documentXML.path) else {
            throw PlanningToolError.fileReadFailed("Invalid docx structure")
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
    
    private static func extractTextFromXML(_ data: Data, textElements: [String]) -> String {
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

// MARK: - Errors

enum PlanningToolError: Error, LocalizedError {
    case fileReadFailed(String)
    case toolExecutionFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .fileReadFailed(let message):
            return "Failed to read file: \(message)"
        case .toolExecutionFailed(let message):
            return "Tool execution failed: \(message)"
        }
    }
}
