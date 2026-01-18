//
//  TaskFileStorage.swift
//  HivecrewAPI
//
//  File storage management for API uploads and downloads
//

import Foundation
import HivecrewShared

/// Manages file storage for API uploads and task outputs
public actor TaskFileStorage {
    
    /// Base directory for all API file storage
    private let baseDirectory: URL
    
    /// Directory for uploaded input files
    private var uploadsDirectory: URL {
        baseDirectory.appendingPathComponent("Uploads")
    }
    
    /// Directory for task output files
    private var outputDirectory: URL {
        baseDirectory.appendingPathComponent("Output")
    }
    
    public init(baseDirectory: URL? = nil) {
        self.baseDirectory = baseDirectory ?? AppPaths.appSupportDirectory
    }
    
    // MARK: - Directory Management
    
    /// Ensure the storage directories exist
    public func ensureDirectoriesExist() throws {
        try FileManager.default.createDirectory(at: uploadsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }
    
    /// Get the uploads directory for a specific task
    public func uploadsDirectory(for taskId: String) -> URL {
        uploadsDirectory.appendingPathComponent(taskId)
    }
    
    /// Get the output directory for a specific task
    public func outputDirectory(for taskId: String) -> URL {
        outputDirectory.appendingPathComponent(taskId)
    }
    
    // MARK: - File Upload
    
    /// Save uploaded file data for a task
    /// - Parameters:
    ///   - data: The file data
    ///   - filename: Original filename
    ///   - taskId: Task ID
    /// - Returns: Full path to the saved file
    public func saveUploadedFile(data: Data, filename: String, taskId: String) throws -> URL {
        let taskUploadsDir = uploadsDirectory(for: taskId)
        try FileManager.default.createDirectory(at: taskUploadsDir, withIntermediateDirectories: true)
        
        // Sanitize filename to prevent directory traversal
        let sanitizedFilename = sanitizeFilename(filename)
        let fileURL = taskUploadsDir.appendingPathComponent(sanitizedFilename)
        
        try data.write(to: fileURL)
        return fileURL
    }
    
    /// Get all uploaded files for a task
    public func getUploadedFiles(for taskId: String) throws -> [APIFileDetail] {
        let taskUploadsDir = uploadsDirectory(for: taskId)
        return try listFiles(in: taskUploadsDir, isInput: true)
    }
    
    /// Get paths to all uploaded files for a task (for passing to TaskService)
    public func getUploadedFilePaths(for taskId: String) throws -> [String] {
        let taskUploadsDir = uploadsDirectory(for: taskId)
        guard FileManager.default.fileExists(atPath: taskUploadsDir.path) else {
            return []
        }
        
        let contents = try FileManager.default.contentsOfDirectory(at: taskUploadsDir, includingPropertiesForKeys: nil)
        return contents.map { $0.path }
    }
    
    // MARK: - File Output
    
    /// Copy output files from the task's outbox to the API output directory
    /// Called after task completion
    public func storeOutputFiles(from outboxPath: URL, taskId: String) throws {
        let taskOutputDir = outputDirectory(for: taskId)
        try FileManager.default.createDirectory(at: taskOutputDir, withIntermediateDirectories: true)
        
        guard FileManager.default.fileExists(atPath: outboxPath.path) else {
            return
        }
        
        let contents = try FileManager.default.contentsOfDirectory(at: outboxPath, includingPropertiesForKeys: nil)
        for file in contents {
            let destination = taskOutputDir.appendingPathComponent(file.lastPathComponent)
            // Remove existing file if present
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: file, to: destination)
        }
    }
    
    /// Get all output files for a task
    public func getOutputFiles(for taskId: String) throws -> [APIFileDetail] {
        let taskOutputDir = outputDirectory(for: taskId)
        return try listFiles(in: taskOutputDir, isInput: false)
    }
    
    // MARK: - File Download
    
    /// Get file data for download
    public func getFileData(taskId: String, filename: String, isInput: Bool) throws -> (data: Data, mimeType: String) {
        let directory = isInput ? uploadsDirectory(for: taskId) : outputDirectory(for: taskId)
        let sanitizedFilename = sanitizeFilename(filename)
        let fileURL = directory.appendingPathComponent(sanitizedFilename)
        
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw APIError.notFound("File '\(filename)' not found")
        }
        
        let data = try Data(contentsOf: fileURL)
        let mimeType = APIFile.mimeType(for: filename)
        
        return (data, mimeType)
    }
    
    // MARK: - Cleanup
    
    /// Delete all files associated with a task
    public func deleteTaskFiles(taskId: String) throws {
        let taskUploadsDir = uploadsDirectory(for: taskId)
        let taskOutputDir = outputDirectory(for: taskId)
        
        if FileManager.default.fileExists(atPath: taskUploadsDir.path) {
            try FileManager.default.removeItem(at: taskUploadsDir)
        }
        
        if FileManager.default.fileExists(atPath: taskOutputDir.path) {
            try FileManager.default.removeItem(at: taskOutputDir)
        }
    }
    
    // MARK: - Helpers
    
    /// List files in a directory with metadata
    private func listFiles(in directory: URL, isInput: Bool) throws -> [APIFileDetail] {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return []
        }
        
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey]
        )
        
        return try contents.map { url in
            let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])
            let size = Int64(attributes.fileSize ?? 0)
            let mimeType = APIFile.mimeType(for: url.lastPathComponent)
            let date = attributes.creationDate ?? attributes.contentModificationDate
            
            return APIFileDetail(
                name: url.lastPathComponent,
                size: size,
                mimeType: mimeType,
                uploadedAt: isInput ? date : nil,
                createdAt: isInput ? nil : date
            )
        }
    }
    
    /// Sanitize filename to prevent directory traversal attacks
    private func sanitizeFilename(_ filename: String) -> String {
        // Remove any path components and keep only the filename
        let components = filename.components(separatedBy: CharacterSet(charactersIn: "/\\"))
        let basename = components.last ?? filename
        
        // Remove leading dots to prevent hidden files
        var sanitized = basename
        while sanitized.hasPrefix(".") {
            sanitized = String(sanitized.dropFirst())
        }
        
        // Default to "file" if empty
        if sanitized.isEmpty {
            sanitized = "file"
        }
        
        return sanitized
    }
}
