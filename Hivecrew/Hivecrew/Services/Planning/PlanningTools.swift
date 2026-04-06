//
//  PlanningTools.swift
//  Hivecrew
//
//  Host-side tools for the planning agent (no VM required)
//

import Foundation
import AppKit
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
    
    /// Read file content by delegating to the shared `HostFileReader`.
    private static func readFileContent(at url: URL) async throws -> PlanningToolResult {
        let result = try await HostFileReader.read(at: url)
        if result.hasImage, let base64 = result.imageBase64, let mime = result.imageMimeType {
            return .image(description: result.text, base64: base64, mimeType: mime)
        }
        return .text(result.text)
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
