//
//  TemplateDownloadService.swift
//  Hivecrew
//
//  Service for downloading and installing VM templates from remote sources
//

import Foundation
import HivecrewShared
import Combine

/// Service for downloading and installing VM templates
@MainActor
public class TemplateDownloadService: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published public private(set) var isDownloading = false
    @Published public private(set) var isPaused = false
    @Published public private(set) var progress: TemplateDownloadProgress?
    @Published public private(set) var currentTask: URLSessionTask?
    @Published public private(set) var hasResumableDownload = false
    @Published public private(set) var resumableTemplateId: String?
    @Published public internal(set) var updateAvailable = false
    @Published public internal(set) var availableUpdate: RemoteTemplate?
    @Published public internal(set) var isCheckingForUpdates = false
    @Published public internal(set) var lastUpdateCheck: Date?
    
    // MARK: - Private Properties
    
    private var activeSession: URLSession?
    private var downloadTask: Task<String, Error>?
    private let fileManager = FileManager.default
    
    private var downloadsDirectory: URL {
        let url = AppPaths.appSupportDirectory.appendingPathComponent("Downloads", isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    
    private var downloadStatePath: URL {
        downloadsDirectory.appendingPathComponent("download-state.json")
    }
    
    public var lastKnownCompatibleVersion: String? {
        get { UserDefaults.standard.string(forKey: "lastKnownCompatibleGoldenVersion") }
        set { UserDefaults.standard.set(newValue, forKey: "lastKnownCompatibleGoldenVersion") }
    }
    
    public var lastKnownCompatibleId: String? {
        get { UserDefaults.standard.string(forKey: "lastKnownCompatibleGoldenId") }
        set { UserDefaults.standard.set(newValue, forKey: "lastKnownCompatibleGoldenId") }
    }
    
    public var skippedVersion: String? {
        get { UserDefaults.standard.string(forKey: "skippedTemplateVersion") }
        set { UserDefaults.standard.set(newValue, forKey: "skippedTemplateVersion") }
    }
    
    // MARK: - Singleton
    
    public static let shared = TemplateDownloadService()
    
    private init() {
        checkForResumableDownload()
        if let date = UserDefaults.standard.object(forKey: "lastTemplateUpdateCheckDate") as? Date {
            lastUpdateCheck = date
        }
    }
    
    // MARK: - Update Checking (delegates to extension)
    
    @discardableResult
    public func checkForUpdates(force: Bool = false) async -> RemoteTemplate? {
        return await checkForUpdatesFromManifest(force: force)
    }
    
    public func shouldPromptForUpdate() -> Bool {
        guard updateAvailable, let update = availableUpdate else { return false }
        if let skipped = skippedVersion, skipped == update.version { return false }
        return true
    }
    
    public func skipVersion(_ version: String) { skippedVersion = version }
    public func askLater() { }
    public func clearSkippedVersion() { skippedVersion = nil }
    
    public func markTemplateAsCompatible(_ template: RemoteTemplate) {
        lastKnownCompatibleVersion = template.version
        lastKnownCompatibleId = template.id
        updateAvailable = false
        availableUpdate = nil
    }
    
    public func updateTemplate(_ template: RemoteTemplate, removingOld oldTemplateId: String?) async throws -> String {
        let newTemplateId = try await downloadTemplate(template)
        if let oldId = oldTemplateId, oldId != newTemplateId {
            let oldTemplatePath = AppPaths.templatesDirectory.appendingPathComponent(oldId)
            try? fileManager.removeItem(at: oldTemplatePath)
        }
        clearSkippedVersion()
        return newTemplateId
    }

    public func getCachedManifest() -> TemplateManifest? {
        guard let data = UserDefaults.standard.data(forKey: "cachedTemplateManifest") else { return nil }
        return try? JSONDecoder().decode(TemplateManifest.self, from: data)
    }
    
    // MARK: - Resume State Management
    
    public func checkForResumableDownload() {
        guard let state = loadDownloadState() else {
            hasResumableDownload = false
            resumableTemplateId = nil
            return
        }
        let partialURL = URL(fileURLWithPath: state.partialFilePath)
        if fileManager.fileExists(atPath: partialURL.path) {
            hasResumableDownload = true
            resumableTemplateId = state.templateId
        } else {
            clearDownloadState()
            hasResumableDownload = false
            resumableTemplateId = nil
        }
    }
    
    public func getResumableDownloadInfo() -> (templateId: String, bytesDownloaded: Int64, totalBytes: Int64)? {
        guard let state = loadDownloadState() else { return nil }
        return (state.templateId, state.bytesDownloaded, state.expectedSize)
    }
    
    private func loadDownloadState() -> DownloadState? {
        guard fileManager.fileExists(atPath: downloadStatePath.path),
              let data = try? Data(contentsOf: downloadStatePath),
              let state = try? JSONDecoder().decode(DownloadState.self, from: data) else { return nil }
        return state
    }
    
    func saveDownloadState(_ state: DownloadState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: downloadStatePath)
    }
    
    private func clearDownloadState() {
        try? fileManager.removeItem(at: downloadStatePath)
    }
    
    public func clearPartialDownload() {
        if let state = loadDownloadState() {
            try? fileManager.removeItem(atPath: state.partialFilePath)
        }
        clearDownloadState()
        hasResumableDownload = false
        resumableTemplateId = nil
    }
    
    // MARK: - Download Methods
    
    public func downloadTemplate(_ template: RemoteTemplate, resume: Bool = true) async throws -> String {
        guard !isDownloading else {
            throw TemplateDownloadError.downloadFailed("A download is already in progress")
        }
        
        isDownloading = true
        isPaused = false
        
        var startingBytes: Int64 = 0
        if resume, let state = loadDownloadState(), state.templateId == template.id {
            let partialURL = URL(fileURLWithPath: state.partialFilePath)
            if fileManager.fileExists(atPath: partialURL.path) {
                startingBytes = state.bytesDownloaded
            }
        }
        
        let expectedSize = template.sizeBytes ?? 0
        progress = TemplateDownloadProgress(phase: .downloading, bytesDownloaded: startingBytes, totalBytes: expectedSize, estimatedTimeRemaining: nil)
        
        defer { isDownloading = false }
        
        do {
            let (archivePath, actualSize) = try await downloadArchive(from: template.url, templateId: template.id, resumeFrom: resume ? startingBytes : 0)
            
            clearDownloadState()
            hasResumableDownload = false
            resumableTemplateId = nil
            
            progress = TemplateDownloadProgress(phase: .decompressing, bytesDownloaded: 0, totalBytes: actualSize, estimatedTimeRemaining: nil)
            let extractedPath = try await performDecompressAndExtract(
                archivePath,
                templateId: template.id,
                compressedSize: actualSize,
                onProgress: { [weak self] bytesProcessed in
                    Task { @MainActor in
                        self?.progress = TemplateDownloadProgress(phase: .decompressing, bytesDownloaded: bytesProcessed, totalBytes: actualSize, estimatedTimeRemaining: nil)
                    }
                },
                onExtracting: { [weak self] in
                    Task { @MainActor in
                        self?.progress = TemplateDownloadProgress(phase: .extracting, bytesDownloaded: actualSize, totalBytes: actualSize, estimatedTimeRemaining: nil)
                    }
                }
            )
            
            progress = TemplateDownloadProgress(phase: .configuring, bytesDownloaded: actualSize, totalBytes: actualSize, estimatedTimeRemaining: nil)
            let templateId = try await performConfigureTemplate(extractedPath, template: template)
            
            try? fileManager.removeItem(at: archivePath)
            markTemplateAsCompatible(template)
            progress = TemplateDownloadProgress(phase: .complete, bytesDownloaded: actualSize, totalBytes: actualSize, estimatedTimeRemaining: nil)
            return templateId
            
        } catch {
            if case TemplateDownloadError.cancelled = error { }
            progress = TemplateDownloadProgress(phase: .failed(error.localizedDescription), bytesDownloaded: 0, totalBytes: expectedSize, estimatedTimeRemaining: nil)
            throw error
        }
    }
    
    public func resumeDownload() async throws -> String {
        guard let state = loadDownloadState() else {
            throw TemplateDownloadError.downloadFailed("No resumable download found")
        }
        guard let template = KnownTemplates.all.first(where: { $0.id == state.templateId }) else {
            throw TemplateDownloadError.downloadFailed("Template not found for resume")
        }
        return try await downloadTemplate(template, resume: true)
    }
    
    public func cancelDownload() {
        currentTask?.cancel()
        activeSession?.invalidateAndCancel()
        downloadTask?.cancel()
        isDownloading = false
        isPaused = false
        progress = nil
        checkForResumableDownload()
    }
    
    public func pauseDownload() {
        currentTask?.cancel()
        activeSession?.invalidateAndCancel()
        downloadTask?.cancel()
        isDownloading = false
        isPaused = true
        checkForResumableDownload()
    }

    public func cancelAndDeleteDownload() {
        cancelDownload()
        clearPartialDownload()
    }
    
    // MARK: - Archive Download
    
    private func partialDownloadPath(for templateId: String) -> URL {
        downloadsDirectory.appendingPathComponent("\(templateId).tar.zst.partial")
    }
    
    private func downloadArchive(from url: URL, templateId: String, resumeFrom: Int64) async throws -> (URL, Int64) {
        let partialPath = partialDownloadPath(for: templateId)
        let finalPath = downloadsDirectory.appendingPathComponent("\(templateId).tar.zst")
        
        var resumePosition: Int64 = 0
        if resumeFrom > 0 && fileManager.fileExists(atPath: partialPath.path) {
            let attrs = try? fileManager.attributesOfItem(atPath: partialPath.path)
            resumePosition = (attrs?[.size] as? Int64) ?? 0
        }
        
        let initialState = DownloadState(templateId: templateId, url: url.absoluteString, expectedSize: 0, partialFilePath: partialPath.path, bytesDownloaded: resumePosition, startedAt: Date())
        saveDownloadState(initialState)
        
        var actualTotalSize: Int64 = 0
        var lastBytes: Int64 = resumePosition
        var lastTime = Date()
        var speedSamples: [Double] = []
        let maxSpeedSamples = 10
        
        let downloader = ResumableDownloader(
            url: url,
            destinationPath: partialPath,
            resumeFrom: resumePosition,
            expectedSize: 0,
            templateId: templateId,
            onProgress: { [weak self] bytesWritten, totalBytes in
                actualTotalSize = totalBytes
                let now = Date()
                let elapsed = now.timeIntervalSince(lastTime)
                let bytesInInterval = bytesWritten - lastBytes
                
                var estimatedTime: TimeInterval? = nil
                if elapsed > 0 && bytesInInterval > 0 {
                    let currentSpeed = Double(bytesInInterval) / elapsed
                    speedSamples.append(currentSpeed)
                    if speedSamples.count > maxSpeedSamples { speedSamples.removeFirst() }
                    let avgSpeed = speedSamples.reduce(0, +) / Double(speedSamples.count)
                    if avgSpeed > 0 {
                        estimatedTime = Double(totalBytes - bytesWritten) / avgSpeed
                    }
                    lastBytes = bytesWritten
                    lastTime = now
                }
                
                Task { @MainActor in
                    self?.progress = TemplateDownloadProgress(phase: .downloading, bytesDownloaded: bytesWritten, totalBytes: totalBytes, estimatedTimeRemaining: estimatedTime)
                }
            },
            onStateUpdate: { [weak self] bytesWritten in
                let state = DownloadState(templateId: templateId, url: url.absoluteString, expectedSize: actualTotalSize, partialFilePath: partialPath.path, bytesDownloaded: bytesWritten, startedAt: initialState.startedAt)
                self?.saveDownloadState(state)
            }
        )
        
        do {
            let finalBytes = try await downloader.download()
            try? fileManager.removeItem(at: finalPath)
            try fileManager.moveItem(at: partialPath, to: finalPath)
            return (finalPath, finalBytes)
        } catch is CancellationError {
            saveStateOnError(partialPath: partialPath, templateId: templateId, url: url, actualTotalSize: actualTotalSize, initialState: initialState)
            throw TemplateDownloadError.cancelled
        } catch {
            saveStateOnError(partialPath: partialPath, templateId: templateId, url: url, actualTotalSize: actualTotalSize, initialState: initialState)
            throw error
        }
    }
    
    private func saveStateOnError(partialPath: URL, templateId: String, url: URL, actualTotalSize: Int64, initialState: DownloadState) {
        if let attrs = try? fileManager.attributesOfItem(atPath: partialPath.path),
           let size = attrs[.size] as? Int64 {
            let state = DownloadState(templateId: templateId, url: url.absoluteString, expectedSize: actualTotalSize, partialFilePath: partialPath.path, bytesDownloaded: size, startedAt: initialState.startedAt)
            saveDownloadState(state)
        }
    }
}
