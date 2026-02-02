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

// MARK: - Tool Result Type

/// Result from a planning tool execution, supporting both text and image content
public struct PlanningToolResult {
    /// Text content of the result
    public let text: String
    
    /// Base64-encoded image data (optional)
    public let imageBase64: String?
    
    /// MIME type of the image (optional)
    public let imageMimeType: String?
    
    /// Whether this result contains an image
    public var hasImage: Bool { imageBase64 != nil }
    
    /// Create a text-only result
    public static func text(_ content: String) -> PlanningToolResult {
        PlanningToolResult(text: content, imageBase64: nil, imageMimeType: nil)
    }
    
    /// Create an image result with description
    public static func image(description: String, base64: String, mimeType: String) -> PlanningToolResult {
        PlanningToolResult(text: description, imageBase64: base64, imageMimeType: mimeType)
    }
}

/// Tools available to the planning agent (host-side, no VM)
public struct PlanningTools {
    
    // MARK: - Tool Definitions
    
    /// Tool definition for reading attached files
    public static let readFile = LLMToolDefinition.function(
        name: "read_file",
        description: """
            Read attached files, directories, or webpages for planning.
            - For text files (code, documents, etc.): Returns the file content
            - For directories: Returns a tree of files and folders (then use "DirectoryName/FileName" to read files inside)
            - For images (png, jpg, etc.): Loads the image into context for visual analysis
            - For URLs (http/https): Fetches webpage content as markdown
            
            To read files inside a directory, use the format "DirectoryName/SubPath/FileName.ext".
            Example: After reading "MyFolder" and seeing it contains "image.png", use "MyFolder/image.png" to read it.
            """,
        parameters: [
            "type": "object",
            "properties": [
                "filename": [
                    "type": "string",
                    "description": "The filename, directory path (e.g., 'DirectoryName/FileName.png'), or URL to read"
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
    /// - Returns: The tool result (text or image)
    public static func executeToolCall(
        _ toolCall: LLMToolCall,
        attachedFiles: [String: URL]
    ) async throws -> PlanningToolResult {
        switch toolCall.function.name {
        case "read_file":
            return try await executeReadFile(toolCall, attachedFiles: attachedFiles)
        default:
            return .text("Unknown tool: \(toolCall.function.name)")
        }
    }
    
    /// Execute the read_file tool
    private static func executeReadFile(
        _ toolCall: LLMToolCall,
        attachedFiles: [String: URL]
    ) async throws -> PlanningToolResult {
        let args = try toolCall.function.argumentsDictionary()
        
        guard let filename = args["filename"] as? String else {
            return .text("Error: Missing required parameter 'filename'")
        }
        
        // Check if it's a URL (webpage)
        if filename.lowercased().hasPrefix("http://") || filename.lowercased().hasPrefix("https://") {
            return try await readWebpage(urlString: filename)
        }
        
        // Resolve the file URL from the filename
        guard let fileURL = resolveFileURL(filename: filename, attachedFiles: attachedFiles) else {
            let availableFiles = attachedFiles.keys.sorted().joined(separator: ", ")
            return .text("Error: File '\(filename)' not found. Available files: \(availableFiles). For files inside directories, use the format 'DirectoryName/FileName'.")
        }
        
        // Verify the file exists
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .text("Error: File does not exist at resolved path: \(fileURL.path)")
        }
        
        // Check if it's a directory
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return try readDirectory(at: fileURL)
        }
        
        // Read the file content
        return try await readFileContent(at: fileURL)
    }
    
    /// Resolve a filename to a file URL, supporting both direct attachments and paths within directories
    private static func resolveFileURL(filename: String, attachedFiles: [String: URL]) -> URL? {
        // First, try exact match
        if let url = attachedFiles[filename] {
            return url
        }
        
        // Try to resolve as a subpath of an attached directory
        // e.g., "NYU Template/Slide1.png" -> find "NYU Template" directory and append "Slide1.png"
        let components = filename.split(separator: "/", maxSplits: 1).map(String.init)
        if components.count == 2 {
            let directoryName = components[0]
            let subpath = components[1]
            
            if let directoryURL = attachedFiles[directoryName] {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDir), isDir.boolValue {
                    return directoryURL.appendingPathComponent(subpath)
                }
            }
        }
        
        // Try matching just the filename (for when user provides just the file name)
        let justFilename = (filename as NSString).lastPathComponent
        for (_, url) in attachedFiles {
            if url.lastPathComponent == justFilename {
                return url
            }
        }
        
        return nil
    }
    
    /// Read file content with support for various formats
    private static func readFileContent(at url: URL) async throws -> PlanningToolResult {
        let fileExtension = url.pathExtension.lowercased()
        
        switch fileExtension {
        // PDF
        case "pdf":
            return .text(try extractTextFromPDF(at: url))
            
        // Office documents
        case "docx":
            return .text(try extractTextFromOfficeDocument(at: url, type: .docx))
        case "xlsx":
            return .text(try extractTextFromOfficeDocument(at: url, type: .xlsx))
        case "pptx":
            return .text(try extractTextFromOfficeDocument(at: url, type: .pptx))
            
        // RTF
        case "rtf":
            return .text(try extractTextFromRTF(at: url))
            
        // Plist
        case "plist":
            return .text(try extractTextFromPlist(at: url))
            
        // Images - load as base64 for visual analysis
        case "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "bmp":
            do {
                return try readImage(at: url)
            } catch {
                // Fallback to description if image loading fails
                return .text(describeImageFallback(at: url, error: error))
            }
            
        // Plain text and code files
        default:
            return .text(try readTextFile(at: url))
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
    
    /// Read an image file and return it as base64-encoded data for visual analysis
    private static func readImage(at url: URL) throws -> PlanningToolResult {
        // Read the image data
        let imageData = try Data(contentsOf: url)
        
        guard let image = NSImage(data: imageData) else {
            throw PlanningToolError.fileReadFailed("Failed to load image")
        }
        
        // Get image dimensions
        guard let bitmapRep = image.representations.first else {
            throw PlanningToolError.fileReadFailed("Failed to get image representation")
        }
        
        let width = bitmapRep.pixelsWide > 0 ? bitmapRep.pixelsWide : Int(image.size.width)
        let height = bitmapRep.pixelsHigh > 0 ? bitmapRep.pixelsHigh : Int(image.size.height)
        
        let filename = url.lastPathComponent
        let fileSize = imageData.count
        let fileSizeStr = ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
        
        // Determine original MIME type
        let originalMimeType = mimeTypeForExtension(url.pathExtension)
        
        // Convert to base64
        let base64Data = imageData.base64EncodedString()
        
        // Use ImageDownscaler to compress/resize if needed (medium scale = max 1024px)
        let (finalBase64, finalMimeType): (String, String)
        if let downscaled = ImageDownscaler.downscale(
            base64Data: base64Data,
            mimeType: originalMimeType,
            to: .medium
        ) {
            finalBase64 = downscaled.data
            finalMimeType = downscaled.mimeType
        } else {
            // Fallback to original if downscaling fails
            finalBase64 = base64Data
            finalMimeType = originalMimeType
        }
        
        // Build description text
        let description = """
            [Image: \(filename)]
            Dimensions: \(width) x \(height) pixels
            File size: \(fileSizeStr)
            Format: \(url.pathExtension.uppercased())
            """
        
        return .image(description: description, base64: finalBase64, mimeType: finalMimeType)
    }
    
    /// Get MIME type for a file extension
    private static func mimeTypeForExtension(_ ext: String) -> String {
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
    
    /// Fallback description when image loading fails
    private static func describeImageFallback(at url: URL, error: Error) -> String {
        let filename = url.lastPathComponent
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let fileSizeStr = ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
        
        return """
            [Image File - Could not load for visual analysis]
            Filename: \(filename)
            File size: \(fileSizeStr)
            Format: \(url.pathExtension.uppercased())
            Error: \(error.localizedDescription)
            
            Note: The image could not be loaded into context. The agent will have access to view this image during execution.
            """
    }
    
    // MARK: - Directory Reading
    
    /// Read a directory and return a tree structure
    private static func readDirectory(at url: URL, maxDepth: Int = 3) throws -> PlanningToolResult {
        let directoryName = url.lastPathComponent
        let tree = try buildDirectoryTree(at: url, depth: 0, maxDepth: maxDepth, prefix: "")
        let header = "Directory: \(directoryName)/\n"
        let footer = "\n---\nTo read a file from this directory, use: \"\(directoryName)/<filename>\"\nExample: \"\(directoryName)/\(exampleFileName(in: url))\""
        return .text(header + tree + footer)
    }
    
    /// Get an example filename from a directory for the usage hint
    private static func exampleFileName(in url: URL) -> String {
        if let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]),
           let firstFile = contents.first(where: { 
               var isDir: ObjCBool = false
               FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDir)
               return !isDir.boolValue
           }) {
            return firstFile.lastPathComponent
        }
        return "<filename>"
    }
    
    /// Recursively build a directory tree string
    private static func buildDirectoryTree(
        at url: URL,
        depth: Int,
        maxDepth: Int,
        prefix: String
    ) throws -> String {
        guard depth < maxDepth else {
            return prefix + "└── ...\n"
        }
        
        let fileManager = FileManager.default
        let contents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        
        // Sort: directories first, then files, both alphabetically
        let sorted = contents.sorted { a, b in
            let aIsDir = (try? a.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let bIsDir = (try? b.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if aIsDir != bIsDir {
                return aIsDir // Directories first
            }
            return a.lastPathComponent.lowercased() < b.lastPathComponent.lowercased()
        }
        
        var result = ""
        
        for (index, item) in sorted.enumerated() {
            let isLast = index == sorted.count - 1
            let connector = isLast ? "└── " : "├── "
            let childPrefix = isLast ? "    " : "│   "
            
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let name = item.lastPathComponent + (isDirectory ? "/" : "")
            
            result += prefix + connector + name + "\n"
            
            if isDirectory {
                result += try buildDirectoryTree(
                    at: item,
                    depth: depth + 1,
                    maxDepth: maxDepth,
                    prefix: prefix + childPrefix
                )
            }
        }
        
        return result
    }
    
    // MARK: - Webpage Reading
    
    /// Read a webpage and return its content as markdown
    private static func readWebpage(urlString: String) async throws -> PlanningToolResult {
        guard let url = URL(string: urlString) else {
            return .text("Error: Invalid URL '\(urlString)'")
        }
        
        do {
            let content = try await WebpageReader.readWebpage(url: url)
            return .text(content)
        } catch {
            return .text("Error reading webpage: \(error.localizedDescription)")
        }
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
