//
//  APIFile.swift
//  HivecrewAPI
//
//  File metadata model for API responses
//

import Foundation

/// File metadata for API responses
public struct APIFile: Codable, Sendable {
    public let name: String
    public let size: Int64
    public let mimeType: String
    
    public init(name: String, size: Int64, mimeType: String) {
        self.name = name
        self.size = size
        self.mimeType = mimeType
    }
}

/// Extended file metadata with timestamp
public struct APIFileDetail: Codable, Sendable {
    public let name: String
    public let size: Int64
    public let mimeType: String
    public let uploadedAt: Date?
    public let createdAt: Date?
    
    public init(name: String, size: Int64, mimeType: String, uploadedAt: Date? = nil, createdAt: Date? = nil) {
        self.name = name
        self.size = size
        self.mimeType = mimeType
        self.uploadedAt = uploadedAt
        self.createdAt = createdAt
    }
}

/// Response for GET /tasks/:id/files
public struct APITaskFilesResponse: Codable, Sendable {
    public let taskId: String
    public let inputFiles: [APIFileDetail]
    public let outputFiles: [APIFileDetail]
    
    public init(taskId: String, inputFiles: [APIFileDetail], outputFiles: [APIFileDetail]) {
        self.taskId = taskId
        self.inputFiles = inputFiles
        self.outputFiles = outputFiles
    }
}

// MARK: - MIME Type Detection

public extension APIFile {
    /// Detect MIME type from file extension
    static func mimeType(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        
        switch ext {
        // Documents
        case "pdf": return "application/pdf"
        case "doc": return "application/msword"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xls": return "application/vnd.ms-excel"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "ppt": return "application/vnd.ms-powerpoint"
        case "pptx": return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        
        // Text
        case "txt": return "text/plain"
        case "csv": return "text/csv"
        case "json": return "application/json"
        case "xml": return "application/xml"
        case "html", "htm": return "text/html"
        case "css": return "text/css"
        case "js": return "application/javascript"
        case "md": return "text/markdown"
        
        // Images
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "ico": return "image/x-icon"
        
        // Audio
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "m4a": return "audio/mp4"
        
        // Video
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        case "avi": return "video/x-msvideo"
        
        // Archives
        case "zip": return "application/zip"
        case "tar": return "application/x-tar"
        case "gz": return "application/gzip"
        case "rar": return "application/vnd.rar"
        
        // Code
        case "swift": return "text/x-swift"
        case "py": return "text/x-python"
        case "rb": return "text/x-ruby"
        case "java": return "text/x-java"
        case "c", "h": return "text/x-c"
        case "cpp", "hpp": return "text/x-c++"
        
        default: return "application/octet-stream"
        }
    }
}
