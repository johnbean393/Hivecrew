//
//  AttachmentInfo.swift
//  Hivecrew
//
//  Model for tracking task attachment metadata including original and copied paths
//

import Foundation

/// Information about a file attached to a task
/// Tracks both the original location and the copied location (if applicable)
struct AttachmentInfo: Codable, Hashable, Sendable {
    /// Original path where the file was located when attached
    let originalPath: String
    
    /// Path where the file was copied to in the app's Attachments directory
    /// nil if the file was too large to copy (>250MB) or if copying failed
    let copiedPath: String?
    
    /// Size of the file in bytes at the time of attachment
    let fileSize: Int64
    
    /// Original filename (for display purposes)
    var fileName: String {
        URL(fileURLWithPath: originalPath).lastPathComponent
    }
    
    /// Whether the file was copied to the app's directory
    var wasCopied: Bool {
        copiedPath != nil
    }
    
    /// The effective path to use when accessing the file
    /// Prefers copied path if available, falls back to original
    var effectivePath: String {
        copiedPath ?? originalPath
    }
    
    /// Whether the file currently exists at the effective path
    var fileExists: Bool {
        FileManager.default.fileExists(atPath: effectivePath)
    }
    
    /// Maximum file size for copying (250MB)
    static let maxCopySize: Int64 = 250 * 1024 * 1024
    
    /// Create attachment info for a file that was copied
    init(originalPath: String, copiedPath: String?, fileSize: Int64) {
        self.originalPath = originalPath
        self.copiedPath = copiedPath
        self.fileSize = fileSize
    }
    
    /// Create attachment info from just a path (for backwards compatibility migration)
    /// This will check if the file exists and get its size
    init(path: String) {
        self.originalPath = path
        self.copiedPath = nil
        
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? Int64 {
            self.fileSize = size
        } else {
            self.fileSize = 0
        }
    }
}
