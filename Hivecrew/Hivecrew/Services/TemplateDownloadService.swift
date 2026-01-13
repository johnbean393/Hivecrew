//
//  TemplateDownloadService.swift
//  Hivecrew
//
//  Service for downloading and installing VM templates from remote sources
//

import Foundation
import HivecrewShared
import libzstd
import Combine

/// Configuration for remote template downloads
public struct RemoteTemplate: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let version: String
    public let url: URL
    public let sizeBytes: Int64
    public let sha256: String?
    
    public init(
        id: String,
        name: String,
        description: String,
        version: String,
        url: URL,
        sizeBytes: Int64,
        sha256: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.version = version
        self.url = url
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
    }
    
    /// Human-readable size
    public var sizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

/// Known remote templates available for download
public enum KnownTemplates {
    /// The golden template hosted on Cloudflare R2
    public static let goldenV005 = RemoteTemplate(
        id: "golden-v0.0.5",
        name: "Hivecrew Golden Image",
        description: "Pre-configured macOS VM with Hivecrew agent installed",
        version: "0.0.5",
        url: URL(string: "https://templates.hivecrew.org/golden-v0.0.5.tar.zst")!,
        sizeBytes: 21_944_188_032, // ~20.4 GB
        sha256: nil // TODO: Add checksum for verification
    )
    
    /// All available templates for download
    public static let all: [RemoteTemplate] = [goldenV005]
    
    /// The default/recommended template
    public static let `default` = goldenV005
}

/// Progress state for template download
public struct TemplateDownloadProgress: Sendable {
    public enum Phase: Sendable {
        case downloading
        case decompressing
        case extracting
        case configuring
        case complete
        case failed(String)
    }
    
    public let phase: Phase
    public let bytesDownloaded: Int64
    public let totalBytes: Int64
    public let estimatedTimeRemaining: TimeInterval?
    
    public var fractionComplete: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(bytesDownloaded) / Double(totalBytes)
    }
    
    public var percentComplete: Int {
        Int(fractionComplete * 100)
    }
    
    public var phaseDescription: String {
        switch phase {
        case .downloading:
            return "Downloading template..."
        case .decompressing:
            return "Decompressing..."
        case .extracting:
            return "Extracting files..."
        case .configuring:
            return "Configuring template..."
        case .complete:
            return "Complete"
        case .failed(let error):
            return "Failed: \(error)"
        }
    }
}

/// Errors that can occur during template download
public enum TemplateDownloadError: LocalizedError {
    case downloadFailed(String)
    case decompressionFailed(String)
    case extractionFailed(String)
    case configurationFailed(String)
    case cancelled
    case invalidTemplate(String)
    case fileSystemError(String)
    
    public var errorDescription: String? {
        switch self {
        case .downloadFailed(let message):
            return "Download failed: \(message)"
        case .decompressionFailed(let message):
            return "Decompression failed: \(message)"
        case .extractionFailed(let message):
            return "Extraction failed: \(message)"
        case .configurationFailed(let message):
            return "Configuration failed: \(message)"
        case .cancelled:
            return "Download was cancelled"
        case .invalidTemplate(let message):
            return "Invalid template: \(message)"
        case .fileSystemError(let message):
            return "File system error: \(message)"
        }
    }
}

/// Persistent state for resumable downloads
private struct DownloadState: Codable {
    let templateId: String
    let url: String
    let expectedSize: Int64
    let partialFilePath: String
    let bytesDownloaded: Int64
    let startedAt: Date
}

/// Service for downloading and installing VM templates
@MainActor
public class TemplateDownloadService: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published public private(set) var isDownloading = false
    @Published public private(set) var progress: TemplateDownloadProgress?
    @Published public private(set) var currentTask: URLSessionTask?
    @Published public private(set) var hasResumableDownload = false
    @Published public private(set) var resumableTemplateId: String?
    
    // MARK: - Private Properties
    
    private var activeSession: URLSession?
    private var downloadTask: Task<String, Error>?
    private let fileManager = FileManager.default
    
    /// Directory for storing partial downloads
    private var downloadsDirectory: URL {
        let url = AppPaths.appSupportDirectory.appendingPathComponent("Downloads", isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    
    /// Path to the download state file
    private var downloadStatePath: URL {
        downloadsDirectory.appendingPathComponent("download-state.json")
    }
    
    // MARK: - Singleton
    
    public static let shared = TemplateDownloadService()
    
    private init() {
        // Check for resumable downloads on init
        checkForResumableDownload()
    }
    
    // MARK: - Resume State Management
    
    /// Check if there's a resumable download available
    public func checkForResumableDownload() {
        guard let state = loadDownloadState() else {
            hasResumableDownload = false
            resumableTemplateId = nil
            return
        }
        
        // Verify the partial file still exists
        let partialURL = URL(fileURLWithPath: state.partialFilePath)
        if fileManager.fileExists(atPath: partialURL.path) {
            hasResumableDownload = true
            resumableTemplateId = state.templateId
        } else {
            // Clean up orphaned state
            clearDownloadState()
            hasResumableDownload = false
            resumableTemplateId = nil
        }
    }
    
    /// Get info about the resumable download
    public func getResumableDownloadInfo() -> (templateId: String, bytesDownloaded: Int64, totalBytes: Int64)? {
        guard let state = loadDownloadState() else { return nil }
        return (state.templateId, state.bytesDownloaded, state.expectedSize)
    }
    
    private func loadDownloadState() -> DownloadState? {
        guard fileManager.fileExists(atPath: downloadStatePath.path),
              let data = try? Data(contentsOf: downloadStatePath),
              let state = try? JSONDecoder().decode(DownloadState.self, from: data) else {
            return nil
        }
        return state
    }
    
    private func saveDownloadState(_ state: DownloadState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: downloadStatePath)
    }
    
    private func clearDownloadState() {
        try? fileManager.removeItem(at: downloadStatePath)
    }
    
    /// Delete any partial downloads and reset state
    public func clearPartialDownload() {
        if let state = loadDownloadState() {
            try? fileManager.removeItem(atPath: state.partialFilePath)
        }
        clearDownloadState()
        hasResumableDownload = false
        resumableTemplateId = nil
    }
    
    // MARK: - Public Methods
    
    /// Download and install a remote template
    /// - Parameters:
    ///   - template: The remote template to download
    ///   - resume: If true, attempts to resume a previous partial download
    /// - Returns: The template ID of the installed template
    public func downloadTemplate(_ template: RemoteTemplate, resume: Bool = true) async throws -> String {
        guard !isDownloading else {
            throw TemplateDownloadError.downloadFailed("A download is already in progress")
        }
        
        isDownloading = true
        
        // Check for existing partial download
        var startingBytes: Int64 = 0
        if resume, let state = loadDownloadState(), state.templateId == template.id {
            let partialURL = URL(fileURLWithPath: state.partialFilePath)
            if fileManager.fileExists(atPath: partialURL.path) {
                startingBytes = state.bytesDownloaded
            }
        }
        
        progress = TemplateDownloadProgress(
            phase: .downloading,
            bytesDownloaded: startingBytes,
            totalBytes: template.sizeBytes,
            estimatedTimeRemaining: nil
        )
        
        defer {
            isDownloading = false
        }
        
        do {
            // Step 1: Download the archive (with resume support)
            let archivePath = try await downloadArchive(
                from: template.url,
                templateId: template.id,
                expectedSize: template.sizeBytes,
                resumeFrom: resume ? startingBytes : 0
            )
            
            // Clear download state after successful download
            clearDownloadState()
            hasResumableDownload = false
            resumableTemplateId = nil
            
            // Step 2: Decompress with zstd
            progress = TemplateDownloadProgress(
                phase: .decompressing,
                bytesDownloaded: template.sizeBytes,
                totalBytes: template.sizeBytes,
                estimatedTimeRemaining: nil
            )
            let tarPath = try await decompressZstd(archivePath)
            
            // Step 3: Extract tar archive
            progress = TemplateDownloadProgress(
                phase: .extracting,
                bytesDownloaded: template.sizeBytes,
                totalBytes: template.sizeBytes,
                estimatedTimeRemaining: nil
            )
            let extractedPath = try await extractTar(tarPath, templateId: template.id)
            
            // Step 4: Configure the template
            progress = TemplateDownloadProgress(
                phase: .configuring,
                bytesDownloaded: template.sizeBytes,
                totalBytes: template.sizeBytes,
                estimatedTimeRemaining: nil
            )
            let templateId = try await configureTemplate(extractedPath, template: template)
            
            // Cleanup temporary files
            try? fileManager.removeItem(at: archivePath)
            try? fileManager.removeItem(at: tarPath)
            
            progress = TemplateDownloadProgress(
                phase: .complete,
                bytesDownloaded: template.sizeBytes,
                totalBytes: template.sizeBytes,
                estimatedTimeRemaining: nil
            )
            
            return templateId
            
        } catch {
            // Don't clear state on error - allows resume
            if case TemplateDownloadError.cancelled = error {
                // Download was cancelled, state is preserved for resume
            }
            
            progress = TemplateDownloadProgress(
                phase: .failed(error.localizedDescription),
                bytesDownloaded: 0,
                totalBytes: template.sizeBytes,
                estimatedTimeRemaining: nil
            )
            throw error
        }
    }
    
    /// Resume a previously interrupted download
    public func resumeDownload() async throws -> String {
        guard let state = loadDownloadState() else {
            throw TemplateDownloadError.downloadFailed("No resumable download found")
        }
        
        // Find the matching template
        guard let template = KnownTemplates.all.first(where: { $0.id == state.templateId }) else {
            throw TemplateDownloadError.downloadFailed("Template not found for resume")
        }
        
        return try await downloadTemplate(template, resume: true)
    }
    
    /// Cancel the current download (preserves partial file for resume)
    public func cancelDownload() {
        currentTask?.cancel()
        activeSession?.invalidateAndCancel()
        downloadTask?.cancel()
        isDownloading = false
        progress = nil
        
        // Update resumable state
        checkForResumableDownload()
    }
    
    /// Cancel and delete the partial download
    public func cancelAndDeleteDownload() {
        cancelDownload()
        clearPartialDownload()
    }
    
    // MARK: - Private Methods
    
    /// Path for partial download file
    private func partialDownloadPath(for templateId: String) -> URL {
        downloadsDirectory.appendingPathComponent("\(templateId).tar.zst.partial")
    }
    
    /// Download the archive from URL with progress reporting and resume support
    private func downloadArchive(from url: URL, templateId: String, expectedSize: Int64, resumeFrom: Int64) async throws -> URL {
        let partialPath = partialDownloadPath(for: templateId)
        let finalPath = downloadsDirectory.appendingPathComponent("\(templateId).tar.zst")
        
        // Determine actual resume position from file size
        var resumePosition: Int64 = 0
        if resumeFrom > 0 && fileManager.fileExists(atPath: partialPath.path) {
            let attrs = try? fileManager.attributesOfItem(atPath: partialPath.path)
            resumePosition = (attrs?[.size] as? Int64) ?? 0
        }
        
        // Save initial state for resume capability
        let initialState = DownloadState(
            templateId: templateId,
            url: url.absoluteString,
            expectedSize: expectedSize,
            partialFilePath: partialPath.path,
            bytesDownloaded: resumePosition,
            startedAt: Date()
        )
        saveDownloadState(initialState)
        
        // Use the efficient delegate-based downloader
        let downloader = ResumableDownloader(
            url: url,
            destinationPath: partialPath,
            resumeFrom: resumePosition,
            expectedSize: expectedSize,
            templateId: templateId,
            onProgress: { [weak self] bytesWritten, totalBytes in
                Task { @MainActor in
                    self?.progress = TemplateDownloadProgress(
                        phase: .downloading,
                        bytesDownloaded: bytesWritten,
                        totalBytes: totalBytes,
                        estimatedTimeRemaining: nil
                    )
                }
            },
            onStateUpdate: { [weak self] bytesWritten in
                let state = DownloadState(
                    templateId: templateId,
                    url: url.absoluteString,
                    expectedSize: expectedSize,
                    partialFilePath: partialPath.path,
                    bytesDownloaded: bytesWritten,
                    startedAt: initialState.startedAt
                )
                self?.saveDownloadState(state)
            }
        )
        
        do {
            let finalBytes = try await downloader.download()
            
            // Log download completion (actual size may differ slightly from expected)
            print("Download complete: \(finalBytes) bytes")
            
            // Rename partial to final
            try? fileManager.removeItem(at: finalPath)
            try fileManager.moveItem(at: partialPath, to: finalPath)
            
            return finalPath
            
        } catch is CancellationError {
            // Save state before throwing
            if let attrs = try? fileManager.attributesOfItem(atPath: partialPath.path),
               let size = attrs[.size] as? Int64 {
                let state = DownloadState(
                    templateId: templateId,
                    url: url.absoluteString,
                    expectedSize: expectedSize,
                    partialFilePath: partialPath.path,
                    bytesDownloaded: size,
                    startedAt: initialState.startedAt
                )
                saveDownloadState(state)
            }
            throw TemplateDownloadError.cancelled
        } catch {
            // Save state for potential resume
            if let attrs = try? fileManager.attributesOfItem(atPath: partialPath.path),
               let size = attrs[.size] as? Int64 {
                let state = DownloadState(
                    templateId: templateId,
                    url: url.absoluteString,
                    expectedSize: expectedSize,
                    partialFilePath: partialPath.path,
                    bytesDownloaded: size,
                    startedAt: initialState.startedAt
                )
                saveDownloadState(state)
            }
            throw error
        }
    }
    
    /// Decompress a zstd-compressed file using streaming decompression
    private func decompressZstd(_ sourcePath: URL) async throws -> URL {
        let outputPath = sourcePath.deletingPathExtension() // Remove .zst extension
        
        return try await Task.detached(priority: .userInitiated) {
            // Use streaming decompression for large files
            let dctx = ZSTD_createDCtx()
            guard dctx != nil else {
                throw TemplateDownloadError.decompressionFailed("Failed to create decompression context")
            }
            defer { ZSTD_freeDCtx(dctx) }
            
            // Open input and output files
            guard let inputHandle = FileHandle(forReadingAtPath: sourcePath.path) else {
                throw TemplateDownloadError.decompressionFailed("Cannot open compressed file for reading")
            }
            defer { try? inputHandle.close() }
            
            // Create output file
            FileManager.default.createFile(atPath: outputPath.path, contents: nil)
            guard let outputHandle = FileHandle(forWritingAtPath: outputPath.path) else {
                throw TemplateDownloadError.decompressionFailed("Cannot create output file for writing")
            }
            defer { try? outputHandle.close() }
            
            // Buffer sizes
            let inputBufferSize = ZSTD_DStreamInSize()
            let outputBufferSize = ZSTD_DStreamOutSize()
            
            var inputBuffer = [UInt8](repeating: 0, count: inputBufferSize)
            var outputBuffer = [UInt8](repeating: 0, count: outputBufferSize)
            
            // Stream decompression
            while true {
                let inputData = inputHandle.readData(ofLength: inputBufferSize)
                if inputData.isEmpty {
                    break
                }
                
                inputData.copyBytes(to: &inputBuffer, count: inputData.count)
                
                var input = ZSTD_inBuffer(src: inputBuffer, size: inputData.count, pos: 0)
                
                while input.pos < input.size {
                    var output = ZSTD_outBuffer(dst: &outputBuffer, size: outputBufferSize, pos: 0)
                    
                    let result = ZSTD_decompressStream(dctx, &output, &input)
                    
                    if ZSTD_isError(result) != 0 {
                        let errorName = String(cString: ZSTD_getErrorName(result))
                        throw TemplateDownloadError.decompressionFailed("zstd streaming error: \(errorName)")
                    }
                    
                    if output.pos > 0 {
                        let writeData = Data(bytes: outputBuffer, count: output.pos)
                        try outputHandle.write(contentsOf: writeData)
                    }
                }
            }
            
            return outputPath
        }.value
    }
    
    /// Extract a tar archive to the templates directory
    private func extractTar(_ tarPath: URL, templateId: String) async throws -> URL {
        let templatesDir = AppPaths.templatesDirectory
        let expectedPath = templatesDir.appendingPathComponent(templateId)

        return try await Task.detached(priority: .userInitiated) {
            // Remove existing template with same ID to avoid duplicates
            if FileManager.default.fileExists(atPath: expectedPath.path) {
                try? FileManager.default.removeItem(at: expectedPath)
            }
            
            // Use system tar command for extraction
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-xf", tarPath.path, "-C", templatesDir.path]

            let errorPipe = Pipe()
            process.standardError = errorPipe

            try process.run()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                throw TemplateDownloadError.extractionFailed(errorMessage)
            }

            // Check for the expected template path first
            if FileManager.default.fileExists(atPath: expectedPath.path) {
                let diskPath = expectedPath.appendingPathComponent("disk.img")
                if FileManager.default.fileExists(atPath: diskPath.path) {
                    return expectedPath
                }
            }
            
            // Fallback: Find any extracted directory that looks like a template
            let contents = try FileManager.default.contentsOfDirectory(at: templatesDir, includingPropertiesForKeys: [.creationDateKey])
            
            // Sort by creation date (newest first) to find the just-extracted folder
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
        }.value
    }
    
}

// MARK: - Efficient Resumable Downloader

/// Delegate-based downloader for efficient large file downloads with resume support
private class ResumableDownloader: NSObject, URLSessionDataDelegate {
    private let url: URL
    private let destinationPath: URL
    private let resumeFrom: Int64
    private let expectedSize: Int64
    private let templateId: String
    private let onProgress: (Int64, Int64) -> Void
    private let onStateUpdate: (Int64) -> Void
    
    private var fileHandle: FileHandle?
    private var bytesWritten: Int64 = 0
    private var lastProgressUpdate = Date()
    private var lastStateUpdate = Date()
    private var session: URLSession?
    private var dataTask: URLSessionDataTask?
    
    private var continuation: CheckedContinuation<Int64, Error>?
    private var hasResumed = false  // Guard against multiple resumes
    private let lock = NSLock()  // Thread-safe access
    
    // Buffer for reducing write syscalls
    private var writeBuffer = Data()
    private let writeBufferSize = 4 * 1024 * 1024 // 4MB buffer
    
    // Actual content length from server (for accurate verification)
    private var serverContentLength: Int64 = 0
    
    init(
        url: URL,
        destinationPath: URL,
        resumeFrom: Int64,
        expectedSize: Int64,
        templateId: String,
        onProgress: @escaping (Int64, Int64) -> Void,
        onStateUpdate: @escaping (Int64) -> Void
    ) {
        self.url = url
        self.destinationPath = destinationPath
        self.resumeFrom = resumeFrom
        self.expectedSize = expectedSize
        self.templateId = templateId
        self.onProgress = onProgress
        self.onStateUpdate = onStateUpdate
        super.init()
    }
    
    // MARK: - Safe Continuation Handling
    
    private func safeResume(returning value: Int64) {
        lock.lock()
        defer { lock.unlock() }
        
        guard !hasResumed, let cont = continuation else { return }
        hasResumed = true
        continuation = nil
        cont.resume(returning: value)
    }
    
    private func safeResume(throwing error: Error) {
        lock.lock()
        defer { lock.unlock() }
        
        guard !hasResumed, let cont = continuation else { return }
        hasResumed = true
        continuation = nil
        cont.resume(throwing: error)
    }
    
    func download() async throws -> Int64 {
        // Reset state for new download
        hasResumed = false
        
        // Setup file handle
        if resumeFrom == 0 {
            FileManager.default.createFile(atPath: destinationPath.path, contents: nil)
        }
        
        guard let handle = FileHandle(forWritingAtPath: destinationPath.path) else {
            throw TemplateDownloadError.fileSystemError("Cannot open file for writing")
        }
        self.fileHandle = handle
        
        if resumeFrom > 0 {
            try handle.seekToEnd()
            bytesWritten = resumeFrom
        }
        
        // Pre-allocate buffer capacity
        writeBuffer.reserveCapacity(writeBufferSize)
        
        // Create request with Range header for resume
        var request = URLRequest(url: url)
        if resumeFrom > 0 {
            request.setValue("bytes=\(resumeFrom)-", forHTTPHeaderField: "Range")
        }
        
        // Configure session with generous timeouts for large downloads
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300  // 5 minutes between data packets
        config.timeoutIntervalForResource = 60 * 60 * 48  // 48 hours total
        config.waitsForConnectivity = true  // Wait for network instead of failing
        
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.dataTask = session.dataTask(with: request)
            self.dataTask?.resume()
        }
    }
    
    // MARK: - URLSessionDataDelegate
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let httpResponse = response as? HTTPURLResponse else {
            safeResume(throwing: TemplateDownloadError.downloadFailed("Invalid response"))
            completionHandler(.cancel)
            return
        }
        
        // Check for valid response codes
        guard httpResponse.statusCode == 200 || httpResponse.statusCode == 206 else {
            safeResume(throwing: TemplateDownloadError.downloadFailed("Server returned status \(httpResponse.statusCode)"))
            completionHandler(.cancel)
            return
        }
        
        // Capture content length from server for accurate verification
        if let contentLengthStr = httpResponse.value(forHTTPHeaderField: "Content-Length"),
           let contentLength = Int64(contentLengthStr) {
            if httpResponse.statusCode == 206 {
                // For partial content, add resume position to get total
                serverContentLength = resumeFrom + contentLength
            } else {
                serverContentLength = contentLength
            }
        }
        
        // If server doesn't support Range requests, start fresh
        if resumeFrom > 0 && httpResponse.statusCode == 200 {
            do {
                try fileHandle?.truncate(atOffset: 0)
                try fileHandle?.seek(toOffset: 0)
                bytesWritten = 0
            } catch {
                safeResume(throwing: error)
                completionHandler(.cancel)
                return
            }
        }
        
        completionHandler(.allow)
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Append to buffer instead of writing immediately
        writeBuffer.append(data)
        bytesWritten += Int64(data.count)
        
        // Write to disk when buffer is full (reduces syscalls significantly)
        if writeBuffer.count >= writeBufferSize {
            do {
                try fileHandle?.write(contentsOf: writeBuffer)
                writeBuffer.removeAll(keepingCapacity: true)
            } catch {
                dataTask.cancel()
                safeResume(throwing: error)
                return
            }
        }
        
        let now = Date()
        
        // Throttle progress updates to every 500ms to reduce CPU overhead
        if now.timeIntervalSince(lastProgressUpdate) > 0.5 {
            onProgress(bytesWritten, expectedSize)
            lastProgressUpdate = now
        }
        
        // Save state every 60 seconds
        if now.timeIntervalSince(lastStateUpdate) > 60 {
            onStateUpdate(bytesWritten)
            lastStateUpdate = now
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Flush remaining buffer to disk
        if !writeBuffer.isEmpty {
            try? fileHandle?.write(contentsOf: writeBuffer)
            writeBuffer.removeAll()
        }
        
        try? fileHandle?.close()
        session.invalidateAndCancel()
        
        if let error = error {
            // Save state before failing
            onStateUpdate(bytesWritten)
            
            if (error as NSError).code == NSURLErrorCancelled {
                safeResume(throwing: TemplateDownloadError.cancelled)
            } else {
                safeResume(throwing: TemplateDownloadError.downloadFailed(error.localizedDescription))
            }
        } else {
            safeResume(returning: bytesWritten)
        }
    }
}

// MARK: - Template Configuration

extension TemplateDownloadService {
    /// Configure the extracted template with proper metadata
    private func configureTemplate(_ extractedPath: URL, template: RemoteTemplate) async throws -> String {
        // Check if config.json exists, if not create one
        let configPath = extractedPath.appendingPathComponent("config.json")
        let diskPath = extractedPath.appendingPathComponent("disk.img")
        
        guard fileManager.fileExists(atPath: diskPath.path) else {
            throw TemplateDownloadError.invalidTemplate("Missing disk.img")
        }
        
        // Read existing config or create new one
        var configDict: [String: Any]
        if fileManager.fileExists(atPath: configPath.path),
           let data = try? Data(contentsOf: configPath),
           let existingConfig = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            configDict = existingConfig
        } else {
            configDict = [:]
        }
        
        // Get disk size
        let diskAttrs = try fileManager.attributesOfItem(atPath: diskPath.path)
        let diskSize = diskAttrs[.size] as? UInt64 ?? 0
        
        // Use the folder name as template ID, or generate new one
        let templateId = extractedPath.lastPathComponent
        
        // Update config with template info
        configDict["id"] = templateId
        configDict["name"] = configDict["name"] as? String ?? template.name
        configDict["description"] = template.description
        configDict["version"] = template.version
        configDict["diskSize"] = diskSize
        configDict["cpuCount"] = configDict["cpuCount"] as? Int ?? 4
        configDict["memorySize"] = configDict["memorySize"] as? UInt64 ?? (8 * 1024 * 1024 * 1024)
        configDict["downloadedAt"] = ISO8601DateFormatter().string(from: Date())
        configDict["sourceURL"] = template.url.absoluteString
        
        // Write updated config
        let configData = try JSONSerialization.data(withJSONObject: configDict, options: .prettyPrinted)
        try configData.write(to: configPath)
        
        return templateId
    }
}

