//
//  FileToolTypes.swift
//  HivecrewGuestAgent
//
//  File type detection and classification
//

import Foundation

// MARK: - File Type Detection

/// Categorizes files by their extension for appropriate text extraction
enum FileType {
    case plainText
    case pdf
    case rtf
    case officeDocument(OfficeDocumentType)
    case plist
    case image
    case binary
    
    enum OfficeDocumentType {
        case docx
        case xlsx
        case pptx
    }
    
    /// Determine file type from path extension
    static func from(path: String) -> FileType {
        let ext = (path as NSString).pathExtension.lowercased()
        
        switch ext {
        // Plain text formats
        case "txt", "md", "markdown", "csv", "tsv", "json", "xml", "html", "htm",
             "css", "js", "ts", "jsx", "tsx", "py", "rb", "swift", "m", "h",
             "c", "cpp", "cc", "cxx", "hpp", "java", "kt", "go", "rs", "sh",
             "bash", "zsh", "fish", "ps1", "bat", "cmd", "yaml", "yml", "toml",
             "ini", "cfg", "conf", "env", "gitignore", "dockerignore", "log",
             "sql", "graphql", "vue", "svelte", "astro", "php", "pl", "r",
             "scala", "clj", "ex", "exs", "erl", "hs", "elm", "lua", "vim",
             "tex", "bib", "srt", "vtt", "asm", "s", "make", "makefile", "cmake",
             "gradle", "sbt", "pom", "lock", "sum", "mod":
            return .plainText
            
        // PDF
        case "pdf":
            return .pdf
            
        // RTF
        case "rtf", "rtfd":
            return .rtf
            
        // Office documents
        case "docx":
            return .officeDocument(.docx)
        case "xlsx":
            return .officeDocument(.xlsx)
        case "pptx":
            return .officeDocument(.pptx)
            
        // Property lists
        case "plist":
            return .plist
            
        // Images
        case "png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif", "heic", "heif", "ico", "svg":
            return .image
            
        // Default to trying as text, then binary
        default:
            return .plainText
        }
    }
    
    /// MIME type for the file type
    var mimeType: String {
        switch self {
        case .plainText: return "text/plain"
        case .pdf: return "application/pdf"
        case .rtf: return "text/rtf"
        case .officeDocument(.docx): return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case .officeDocument(.xlsx): return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case .officeDocument(.pptx): return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case .plist: return "application/x-plist"
        case .image: return "image/*"
        case .binary: return "application/octet-stream"
        }
    }
}
