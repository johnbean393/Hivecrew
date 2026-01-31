//
//  AttachmentManager.swift
//  Hivecrew
//
//  Service for managing task attachments: copying files to session directory
//

import Foundation
import HivecrewShared

/// Result of validating attachments for a rerun
struct RerunAttachmentValidation {
    /// Attachments that were found and are valid
    let validInfos: [AttachmentInfo]
    /// Attachments that are missing (file no longer exists)
    let missingInfos: [AttachmentInfo]
    
    /// Whether all attachments are valid
    var allValid: Bool { missingInfos.isEmpty }
    
    /// Whether there are any attachments at all
    var hasAttachments: Bool { !validInfos.isEmpty || !missingInfos.isEmpty }
}

/// Service for managing file attachments for tasks
/// Handles copying files under 250MB to the session's Attachments directory
enum AttachmentManager {
    
    // MARK: - Constants
    
    /// Maximum file size for copying (250MB)
    static let maxCopySize: Int64 = 250 * 1024 * 1024
    
    // MARK: - Validation
    
    /// Validate attachments for a rerun, identifying which files are missing
    /// - Parameter originalInfos: AttachmentInfos from the original task
    /// - Returns: Validation result with valid and missing attachments
    static func validateAttachmentsForRerun(originalInfos: [AttachmentInfo]) -> RerunAttachmentValidation {
        let fm = FileManager.default
        var validInfos: [AttachmentInfo] = []
        var missingInfos: [AttachmentInfo] = []
        
        for info in originalInfos {
            // Check if the file exists (prefer copied, fall back to original)
            if let copiedPath = info.copiedPath, fm.fileExists(atPath: copiedPath) {
                validInfos.append(info)
            } else if fm.fileExists(atPath: info.originalPath) {
                validInfos.append(info)
            } else {
                // File no longer exists anywhere
                missingInfos.append(info)
            }
        }
        
        return RerunAttachmentValidation(validInfos: validInfos, missingInfos: missingInfos)
    }
    
    // MARK: - Prepare Attachment Metadata
    
    /// Prepare attachment metadata from file paths (no copying yet)
    /// Called at task creation time before session exists
    /// - Parameter filePaths: Original file paths to attach
    /// - Returns: Array of AttachmentInfo with original paths and sizes (copiedPath is nil)
    static func prepareAttachmentInfos(filePaths: [String]) -> [AttachmentInfo] {
        var infos: [AttachmentInfo] = []
        
        for path in filePaths {
            // Get file size
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let fileSize = attrs[.size] as? Int64 {
                infos.append(AttachmentInfo(
                    originalPath: path,
                    copiedPath: nil,
                    fileSize: fileSize
                ))
            } else {
                // File doesn't exist or can't read attributes, still add with zero size
                print("AttachmentManager: Cannot read attributes for file: \(path)")
                infos.append(AttachmentInfo(
                    originalPath: path,
                    copiedPath: nil,
                    fileSize: 0
                ))
            }
        }
        
        return infos
    }
    
    // MARK: - Copy to Session
    
    /// Copy attachments to the session's Attachments directory
    /// Called when session starts and sessionId is available
    /// Files under 250MB are copied, larger files keep their original reference
    /// - Parameters:
    ///   - infos: Attachment infos to process
    ///   - sessionId: The session ID to copy files to
    /// - Returns: Updated AttachmentInfo array with copiedPath set for copied files
    static func copyAttachmentsToSession(infos: [AttachmentInfo], sessionId: String) throws -> [AttachmentInfo] {
        let fm = FileManager.default
        var updatedInfos: [AttachmentInfo] = []
        
        // Create session attachments directory
        let sessionAttachmentsDir = AppPaths.sessionAttachmentsDirectory(id: sessionId)
        try fm.createDirectory(at: sessionAttachmentsDir, withIntermediateDirectories: true)
        
        for info in infos {
            // Determine source path (prefer existing copied path for reruns, otherwise original)
            let sourcePath: String
            if let copiedPath = info.copiedPath, fm.fileExists(atPath: copiedPath) {
                sourcePath = copiedPath
            } else if fm.fileExists(atPath: info.originalPath) {
                sourcePath = info.originalPath
            } else {
                // File doesn't exist anywhere, skip
                print("AttachmentManager: File no longer exists: \(info.originalPath)")
                continue
            }
            
            let sourceURL = URL(fileURLWithPath: sourcePath)
            
            // Get current file size
            guard let attrs = try? fm.attributesOfItem(atPath: sourcePath),
                  let fileSize = attrs[.size] as? Int64 else {
                continue
            }
            
            // Copy if under size limit
            if fileSize <= maxCopySize {
                let destinationURL = sessionAttachmentsDir.appendingPathComponent(sourceURL.lastPathComponent)
                let finalDestination = uniqueDestination(for: destinationURL)
                
                do {
                    try fm.copyItem(at: sourceURL, to: finalDestination)
                    updatedInfos.append(AttachmentInfo(
                        originalPath: info.originalPath,
                        copiedPath: finalDestination.path,
                        fileSize: fileSize
                    ))
                    print("AttachmentManager: Copied \(sourceURL.lastPathComponent) to session \(sessionId)")
                } catch {
                    // Failed to copy, keep original reference
                    print("AttachmentManager: Failed to copy \(sourcePath): \(error)")
                    updatedInfos.append(AttachmentInfo(
                        originalPath: info.originalPath,
                        copiedPath: nil,
                        fileSize: fileSize
                    ))
                }
            } else {
                // File too large, keep original reference
                print("AttachmentManager: File too large to copy (\(fileSize) bytes): \(info.originalPath)")
                updatedInfos.append(AttachmentInfo(
                    originalPath: info.originalPath,
                    copiedPath: nil,
                    fileSize: fileSize
                ))
            }
        }
        
        return updatedInfos
    }
    
    // MARK: - Prepare for Rerun
    
    /// Prepare attachment infos for a task rerun
    /// Copies metadata from the original task, validating that files still exist
    /// - Parameter originalInfos: AttachmentInfos from the original task
    /// - Returns: Validated AttachmentInfo array for the new task
    static func prepareAttachmentsForRerun(originalInfos: [AttachmentInfo]) -> [AttachmentInfo] {
        let fm = FileManager.default
        var newInfos: [AttachmentInfo] = []
        
        for info in originalInfos {
            // Check if the file exists (prefer copied, fall back to original)
            let sourcePath: String?
            if let copiedPath = info.copiedPath, fm.fileExists(atPath: copiedPath) {
                sourcePath = copiedPath
            } else if fm.fileExists(atPath: info.originalPath) {
                sourcePath = info.originalPath
            } else {
                // File no longer exists anywhere
                print("AttachmentManager: Attachment no longer exists for rerun: \(info.originalPath)")
                sourcePath = nil
            }
            
            if let path = sourcePath {
                // Get current file size
                let fileSize: Int64
                if let attrs = try? fm.attributesOfItem(atPath: path),
                   let size = attrs[.size] as? Int64 {
                    fileSize = size
                } else {
                    fileSize = info.fileSize
                }
                
                // Keep the copied path reference if it exists (will be used as source for new session copy)
                newInfos.append(AttachmentInfo(
                    originalPath: info.originalPath,
                    copiedPath: info.copiedPath,
                    fileSize: fileSize
                ))
            }
        }
        
        return newInfos
    }
    
    // MARK: - Helpers
    
    /// Generate a unique destination URL by appending UUID if file already exists
    private static func uniqueDestination(for url: URL) -> URL {
        let fm = FileManager.default
        
        if !fm.fileExists(atPath: url.path) {
            return url
        }
        
        // File exists, append UUID to filename
        let filename = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let uniqueName = "\(filename)_\(UUID().uuidString.prefix(8)).\(ext)"
        return url.deletingLastPathComponent().appendingPathComponent(uniqueName)
    }
}
