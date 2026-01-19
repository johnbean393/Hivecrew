//
//  ResumableDownloader.swift
//  Hivecrew
//
//  Delegate-based downloader for efficient large file downloads with resume support
//

import Combine
import Foundation

/// Delegate-based downloader for efficient large file downloads with resume support
class ResumableDownloader: NSObject, URLSessionDataDelegate {
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
        
        // Use serverContentLength if available, otherwise expectedSize
        let totalSize = serverContentLength > 0 ? serverContentLength : expectedSize
        
        // Throttle progress updates to every 500ms to reduce CPU overhead
        if now.timeIntervalSince(lastProgressUpdate) > 0.5 {
            onProgress(bytesWritten, totalSize)
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
