//
//  TemplateDownloadService+Extraction.swift
//  Hivecrew
//
//  Decompression and extraction functionality for TemplateDownloadService
//

import Foundation
import HivecrewShared
import libzstd

// MARK: - Decompression and Extraction

extension TemplateDownloadService {
    
    /// Stream decompress .tar.zst and extract directly to templates directory
    func performDecompressAndExtract(_ sourcePath: URL, templateId: String, compressedSize: Int64, onProgress: @escaping (Int64) -> Void, onExtracting: @escaping () -> Void = {}) async throws -> URL {
        let templatesDir = AppPaths.templatesDirectory
        let expectedPath = templatesDir.appendingPathComponent(templateId)

        return try await Task.detached(priority: .userInitiated) {
            // Remove existing template with same ID to avoid duplicates
            if FileManager.default.fileExists(atPath: expectedPath.path) {
                try? FileManager.default.removeItem(at: expectedPath)
            }
            
            // Ensure templates directory exists
            try FileManager.default.createDirectory(at: templatesDir, withIntermediateDirectories: true)
            
            // Create a pipe to connect zstd decompression to tar extraction
            var pipeFDs: [Int32] = [0, 0]
            guard pipe(&pipeFDs) == 0 else {
                throw TemplateDownloadError.decompressionFailed("Failed to create pipe")
            }
            let pipeReadFD = pipeFDs[0]
            let pipeWriteFD = pipeFDs[1]
            
            // Start tar process reading from pipe
            let tarProcess = Process()
            tarProcess.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tarProcess.arguments = ["-xf", "-", "-C", templatesDir.path]
            
            let pipeReadHandle = FileHandle(fileDescriptor: pipeReadFD, closeOnDealloc: false)
            tarProcess.standardInput = pipeReadHandle
            
            let errorPipe = Pipe()
            tarProcess.standardError = errorPipe
            
            try tarProcess.run()
            close(pipeReadFD)
            
            // Decompress and write to pipe
            var decompressionError: Error?
            
            do {
                try Self.decompressZstdToPipe(
                    sourcePath: sourcePath,
                    pipeWriteFD: pipeWriteFD,
                    compressedSize: compressedSize,
                    onProgress: onProgress
                )
            } catch {
                decompressionError = error
            }
            
            close(pipeWriteFD)
            onExtracting()
            tarProcess.waitUntilExit()
            
            if let error = decompressionError {
                throw error
            }
            
            if tarProcess.terminationStatus != 0 {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                throw TemplateDownloadError.extractionFailed("tar failed: \(errorMessage)")
            }
            
            // Find the extracted template
            return try Self.findExtractedTemplate(expectedPath: expectedPath, templatesDir: templatesDir)
        }.value
    }
    
    /// Decompress zstd file and write to pipe
    private nonisolated static func decompressZstdToPipe(sourcePath: URL, pipeWriteFD: Int32, compressedSize: Int64, onProgress: @escaping (Int64) -> Void) throws {
        let dctx = ZSTD_createDCtx()
        guard dctx != nil else {
            throw TemplateDownloadError.decompressionFailed("Failed to create decompression context")
        }
        defer { ZSTD_freeDCtx(dctx) }
        
        let inputFD = open(sourcePath.path, O_RDONLY)
        guard inputFD >= 0 else {
            throw TemplateDownloadError.decompressionFailed("Cannot open compressed file")
        }
        defer { close(inputFD) }
        
        let inputBufferSize = ZSTD_DStreamInSize()
        let outputBufferSize = ZSTD_DStreamOutSize()
        
        let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: inputBufferSize)
        let outputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: outputBufferSize)
        defer {
            inputBuffer.deallocate()
            outputBuffer.deallocate()
        }
        
        var totalBytesRead: Int64 = 0
        var lastProgressUpdate = Date()
        
        while true {
            let bytesRead = read(inputFD, inputBuffer, inputBufferSize)
            if bytesRead <= 0 { break }
            
            totalBytesRead += Int64(bytesRead)
            
            let now = Date()
            if now.timeIntervalSince(lastProgressUpdate) > 0.5 {
                onProgress(totalBytesRead)
                lastProgressUpdate = now
            }
            
            var input = ZSTD_inBuffer(src: inputBuffer, size: bytesRead, pos: 0)
            
            while input.pos < input.size {
                var output = ZSTD_outBuffer(dst: outputBuffer, size: outputBufferSize, pos: 0)
                
                let result = ZSTD_decompressStream(dctx, &output, &input)
                
                if ZSTD_isError(result) != 0 {
                    let errorName = String(cString: ZSTD_getErrorName(result))
                    throw TemplateDownloadError.decompressionFailed("zstd error: \(errorName)")
                }
                
                if output.pos > 0 {
                    var totalWritten = 0
                    while totalWritten < output.pos {
                        let written = write(pipeWriteFD, outputBuffer.advanced(by: totalWritten), output.pos - totalWritten)
                        if written < 0 {
                            throw TemplateDownloadError.decompressionFailed("Pipe write error: \(errno)")
                        }
                        totalWritten += written
                    }
                }
            }
        }
        
        onProgress(compressedSize)
    }
    
    /// Find the extracted template directory
    private nonisolated static func findExtractedTemplate(expectedPath: URL, templatesDir: URL) throws -> URL {
        if FileManager.default.fileExists(atPath: expectedPath.path) {
            let diskPath = expectedPath.appendingPathComponent("disk.img")
            if FileManager.default.fileExists(atPath: diskPath.path) {
                return expectedPath
            }
        }
        
        // Fallback: Find any extracted directory that looks like a template
        let contents = try FileManager.default.contentsOfDirectory(at: templatesDir, includingPropertiesForKeys: [.creationDateKey])
        
        let sorted = contents.sorted { url1, url2 in
            let date1 = (try? url1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let date2 = (try? url2.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return date1 > date2
        }
        
        for item in sorted {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir) && isDir.boolValue {
                let diskPath = item.appendingPathComponent("disk.img")
                if FileManager.default.fileExists(atPath: diskPath.path) {
                    return item
                }
            }
        }
        
        throw TemplateDownloadError.extractionFailed("Could not find extracted template directory")
    }
}

// MARK: - Template Configuration

extension TemplateDownloadService {
    
    /// Configure the extracted template with proper metadata
    func performConfigureTemplate(_ extractedPath: URL, template: RemoteTemplate) async throws -> String {
        let configPath = extractedPath.appendingPathComponent("config.json")
        let diskPath = extractedPath.appendingPathComponent("disk.img")
        let fileManager = FileManager.default
        
        guard fileManager.fileExists(atPath: diskPath.path) else {
            throw TemplateDownloadError.invalidTemplate("Missing disk.img")
        }
        
        var configDict: [String: Any]
        if fileManager.fileExists(atPath: configPath.path),
           let data = try? Data(contentsOf: configPath),
           let existingConfig = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            configDict = existingConfig
        } else {
            configDict = [:]
        }
        
        let diskAttrs = try fileManager.attributesOfItem(atPath: diskPath.path)
        let diskSize = diskAttrs[.size] as? UInt64 ?? 0
        
        let templateId = extractedPath.lastPathComponent
        
        configDict["id"] = templateId
        configDict["name"] = configDict["name"] as? String ?? template.name
        configDict["description"] = template.description
        configDict["version"] = template.version
        configDict["diskSize"] = diskSize
        configDict["cpuCount"] = configDict["cpuCount"] as? Int ?? 4
        configDict["memorySize"] = configDict["memorySize"] as? UInt64 ?? (8 * 1024 * 1024 * 1024)
        configDict["downloadedAt"] = ISO8601DateFormatter().string(from: Date())
        configDict["sourceURL"] = template.url.absoluteString
        
        let configData = try JSONSerialization.data(withJSONObject: configDict, options: .prettyPrinted)
        try configData.write(to: configPath)
        
        return templateId
    }
}
