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
    public let sizeBytes: Int64?  // Optional - will be fetched from server if not provided
    public let sha256: String?
    
    public init(
        id: String,
        name: String,
        description: String,
        version: String,
        url: URL,
        sizeBytes: Int64? = nil,
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
    
    /// Human-readable size (returns nil if size unknown)
    public var sizeFormatted: String? {
        guard let sizeBytes = sizeBytes else { return nil }
        return ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

/// Known remote templates available for download
public enum KnownTemplates {
    /// The golden template hosted on Cloudflare R2
    public static let goldenV006 = RemoteTemplate(
        id: "golden-v0.0.6",
        name: "Hivecrew Golden Image",
        description: "Pre-configured macOS 26.2 VM with HivecrewGuestAgent installed",
        version: "0.0.6",
        url: URL(string: "https://templates.hivecrew.org/golden-v0.0.6.tar.zst")!
    )
    
    /// Legacy v0.0.5 (kept for reference)
    public static let goldenV005 = RemoteTemplate(
        id: "golden-v0.0.5",
        name: "Hivecrew Golden Image",
        description: "Pre-configured macOS 26.2 VM with HivecrewGuestAgent installed",
        version: "0.0.5",
        url: URL(string: "https://templates.hivecrew.org/golden-v0.0.5.tar.zst")!
    )
    
    /// All available templates for download
    public static let all: [RemoteTemplate] = [goldenV006, goldenV005]
    
    /// The default/recommended template
    public static let `default` = goldenV006

}

// MARK: - Template Manifest for Auto-Updates

/// Remote manifest describing available templates and compatibility
public struct TemplateManifest: Codable, Sendable {
    public let version: Int
    public let templates: [ManifestTemplate]
    
    public struct ManifestTemplate: Codable, Sendable {
        public let id: String
        public let name: String
        public let version: String
        public let url: String
        public let minimumAppVersion: String?
        public let maximumAppVersion: String?
        
        /// Convert to RemoteTemplate
        public func toRemoteTemplate() -> RemoteTemplate? {
            guard let url = URL(string: url) else { return nil }
            return RemoteTemplate(
                id: id,
                name: name,
                description: "",
                version: version,
                url: url
            )
        }
    }
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
    
    // MARK: - Constants
    
    /// URL for the remote template manifest
    private static let manifestURL = URL(string: "https://templates.hivecrew.org/manifest.json")!
    
    /// Current app version for compatibility checking
    private static let appVersion: String = {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }()
    
    // MARK: - Published Properties
    
    @Published public private(set) var isDownloading = false
    @Published public private(set) var isPaused = false
    @Published public private(set) var progress: TemplateDownloadProgress?
    @Published public private(set) var currentTask: URLSessionTask?
    @Published public private(set) var hasResumableDownload = false
    @Published public private(set) var resumableTemplateId: String?

    /// Whether a template update is available
    @Published public private(set) var updateAvailable = false

    /// The available update template (if any)
    @Published public private(set) var availableUpdate: RemoteTemplate?
    
    /// Whether we're currently checking for updates
    @Published public private(set) var isCheckingForUpdates = false
    
    /// Last time we checked for updates
    @Published public private(set) var lastUpdateCheck: Date?
    
    // MARK: - UserDefaults Keys
    
    private enum DefaultsKeys {
        static let lastKnownCompatibleVersion = "lastKnownCompatibleGoldenVersion"
        static let lastKnownCompatibleId = "lastKnownCompatibleGoldenId"
        static let lastUpdateCheckDate = "lastTemplateUpdateCheckDate"
        static let cachedManifest = "cachedTemplateManifest"
        static let skippedTemplateVersion = "skippedTemplateVersion"
    }
    
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
    
    /// Last known compatible golden image version
    public var lastKnownCompatibleVersion: String? {
        get { UserDefaults.standard.string(forKey: DefaultsKeys.lastKnownCompatibleVersion) }
        set { UserDefaults.standard.set(newValue, forKey: DefaultsKeys.lastKnownCompatibleVersion) }
    }
    
    /// Last known compatible golden image ID
    public var lastKnownCompatibleId: String? {
        get { UserDefaults.standard.string(forKey: DefaultsKeys.lastKnownCompatibleId) }
        set { UserDefaults.standard.set(newValue, forKey: DefaultsKeys.lastKnownCompatibleId) }
    }
    
    /// Version that user chose to skip (won't prompt again for this version)
    public var skippedVersion: String? {
        get { UserDefaults.standard.string(forKey: DefaultsKeys.skippedTemplateVersion) }
        set { UserDefaults.standard.set(newValue, forKey: DefaultsKeys.skippedTemplateVersion) }
    }
    
    // MARK: - Singleton
    
    public static let shared = TemplateDownloadService()
    
    private init() {
        // Check for resumable downloads on init
        checkForResumableDownload()
        
        // Load last update check date
        if let date = UserDefaults.standard.object(forKey: DefaultsKeys.lastUpdateCheckDate) as? Date {
            lastUpdateCheck = date
        }
    }
    
    // MARK: - Update Checking
    
    /// Check for template updates from the remote manifest
    /// - Parameter force: If true, check even if we recently checked
    /// - Returns: The available update template, if any
    @discardableResult
    public func checkForUpdates(force: Bool = false) async -> RemoteTemplate? {
        // Don't check too frequently unless forced
        if !force, let lastCheck = lastUpdateCheck, Date().timeIntervalSince(lastCheck) < 3600 {
            return availableUpdate
        }
        
        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }
        
        do {
            let manifest = try await fetchManifest()
            lastUpdateCheck = Date()
            UserDefaults.standard.set(lastUpdateCheck, forKey: DefaultsKeys.lastUpdateCheckDate)
            
            // Find compatible templates
            let compatibleTemplates = manifest.templates.filter { template in
                isTemplateCompatible(template)
            }
            
            // Sort by version (newest first)
            let sorted = compatibleTemplates.sorted { t1, t2 in
                compareVersions(t1.version, t2.version) == .orderedDescending
            }
            
            guard let newest = sorted.first,
                  let remoteTemplate = newest.toRemoteTemplate() else {
                updateAvailable = false
                availableUpdate = nil
                return nil
            }
            
            // Check if this is newer than what we have
            let currentVersion = lastKnownCompatibleVersion ?? "0.0.0"
            if compareVersions(newest.version, currentVersion) == .orderedDescending {
                updateAvailable = true
                availableUpdate = remoteTemplate
                return remoteTemplate
            }
            
            updateAvailable = false
            availableUpdate = nil
            return nil
            
        } catch {
            print("Failed to check for template updates: \(error)")
            return nil
        }
    }
    
    /// Check if we should prompt the user for an update (respects skipped version)
    public func shouldPromptForUpdate() -> Bool {
        guard updateAvailable, let update = availableUpdate else { return false }
        
        // Don't prompt if user skipped this version
        if let skipped = skippedVersion, skipped == update.version {
            return false
        }
        
        return true
    }
    
    /// User chose to skip this version
    public func skipVersion(_ version: String) {
        skippedVersion = version
    }
    
    /// User chose "ask later" - clear skipped so we ask again next launch
    public func askLater() {
        // Don't set skippedVersion, so we'll prompt again next launch
    }
    
    /// Clear skipped version (e.g., when a newer version is available)
    public func clearSkippedVersion() {
        skippedVersion = nil
    }
    
    /// Fetch the remote manifest
    private func fetchManifest() async throws -> TemplateManifest {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = true
        
        let session = URLSession(configuration: config)
        let (data, response) = try await session.data(from: Self.manifestURL)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw TemplateDownloadError.downloadFailed("Failed to fetch manifest")
        }
        
        let manifest = try JSONDecoder().decode(TemplateManifest.self, from: data)
        
        // Cache the manifest
        UserDefaults.standard.set(data, forKey: DefaultsKeys.cachedManifest)
        
        return manifest
    }
    
    /// Check if a template is compatible with the current app version
    private func isTemplateCompatible(_ template: TemplateManifest.ManifestTemplate) -> Bool {
        // Check minimum app version
        if let minVersion = template.minimumAppVersion {
            if compareVersions(Self.appVersion, minVersion) == .orderedAscending {
                return false // App is too old
            }
        }
        
        // Check maximum app version
        if let maxVersion = template.maximumAppVersion {
            if compareVersions(Self.appVersion, maxVersion) == .orderedDescending {
                return false // App is too new
            }
        }
        
        return true
    }
    
    /// Compare semantic version strings
    private func compareVersions(_ v1: String, _ v2: String) -> ComparisonResult {
        let components1 = v1.split(separator: ".").compactMap { Int($0) }
        let components2 = v2.split(separator: ".").compactMap { Int($0) }
        
        let maxLength = max(components1.count, components2.count)
        
        for i in 0..<maxLength {
            let c1 = i < components1.count ? components1[i] : 0
            let c2 = i < components2.count ? components2[i] : 0
            
            if c1 < c2 { return .orderedAscending }
            if c1 > c2 { return .orderedDescending }
        }
        
        return .orderedSame
    }
    
    /// Update the last known compatible template after successful download
    public func markTemplateAsCompatible(_ template: RemoteTemplate) {
        lastKnownCompatibleVersion = template.version
        lastKnownCompatibleId = template.id
        updateAvailable = false
        availableUpdate = nil
    }
    
    /// Update to a new template, removing the old one after successful download
    /// - Parameters:
    ///   - template: The new template to download
    ///   - oldTemplateId: The ID of the old template to remove after successful update
    /// - Returns: The new template ID
    public func updateTemplate(_ template: RemoteTemplate, removingOld oldTemplateId: String?) async throws -> String {
        let newTemplateId = try await downloadTemplate(template)
        
        // Remove old template after successful download
        if let oldId = oldTemplateId, oldId != newTemplateId {
            let oldTemplatePath = AppPaths.templatesDirectory.appendingPathComponent(oldId)
            try? fileManager.removeItem(at: oldTemplatePath)
            print("Removed old template: \(oldId)")
        }
        
        // Clear skipped version since we've updated
        clearSkippedVersion()
        
        return newTemplateId
    }

    /// Get the cached manifest (if available)
    public func getCachedManifest() -> TemplateManifest? {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKeys.cachedManifest) else {
            return nil
        }
        return try? JSONDecoder().decode(TemplateManifest.self, from: data)
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
        isPaused = false
        
        // Check for existing partial download
        var startingBytes: Int64 = 0
        if resume, let state = loadDownloadState(), state.templateId == template.id {
            let partialURL = URL(fileURLWithPath: state.partialFilePath)
            if fileManager.fileExists(atPath: partialURL.path) {
                startingBytes = state.bytesDownloaded
            }
        }
        
        // Use 0 as placeholder if size unknown - will be updated from Content-Length
        let expectedSize = template.sizeBytes ?? 0
        
        progress = TemplateDownloadProgress(
            phase: .downloading,
            bytesDownloaded: startingBytes,
            totalBytes: expectedSize,
            estimatedTimeRemaining: nil
        )
        
        defer {
            isDownloading = false
        }
        
        do {
            // Step 1: Download the archive (with resume support)
            let (archivePath, actualSize) = try await downloadArchive(
                from: template.url,
                templateId: template.id,
                resumeFrom: resume ? startingBytes : 0
            )
            
            // Clear download state after successful download
            clearDownloadState()
            hasResumableDownload = false
            resumableTemplateId = nil
            
            // Step 2+3: Stream decompress and extract in one pass (no intermediate tar file)
            progress = TemplateDownloadProgress(
                phase: .decompressing,
                bytesDownloaded: 0,
                totalBytes: actualSize,
                estimatedTimeRemaining: nil
            )
            let extractedPath = try await decompressAndExtract(
                archivePath,
                templateId: template.id,
                compressedSize: actualSize,
                onProgress: { [weak self] bytesProcessed in
                    Task { @MainActor in
                        self?.progress = TemplateDownloadProgress(
                            phase: .decompressing,
                            bytesDownloaded: bytesProcessed,
                            totalBytes: actualSize,
                            estimatedTimeRemaining: nil
                        )
                    }
                },
                onExtracting: { [weak self] in
                    Task { @MainActor in
                        self?.progress = TemplateDownloadProgress(
                            phase: .extracting,
                            bytesDownloaded: actualSize,
                            totalBytes: actualSize,
                            estimatedTimeRemaining: nil
                        )
                    }
                }
            )
            
            // Step 4: Configure the template
            progress = TemplateDownloadProgress(
                phase: .configuring,
                bytesDownloaded: actualSize,
                totalBytes: actualSize,
                estimatedTimeRemaining: nil
            )
            let templateId = try await configureTemplate(extractedPath, template: template)
            
            // Cleanup temporary files
            try? fileManager.removeItem(at: archivePath)
            
            // Mark this template as the last known compatible version
            markTemplateAsCompatible(template)

            progress = TemplateDownloadProgress(
                phase: .complete,
                bytesDownloaded: actualSize,
                totalBytes: actualSize,
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
                totalBytes: expectedSize,
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
        isPaused = false
        progress = nil

        // Update resumable state
        checkForResumableDownload()
    }
    
    /// Pause the current download (can be resumed later)
    public func pauseDownload() {
        currentTask?.cancel()
        activeSession?.invalidateAndCancel()
        downloadTask?.cancel()
        isDownloading = false
        isPaused = true
        // Keep progress to show paused state
        
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
    /// Downloads archive and returns (path, actualSize)
    private func downloadArchive(from url: URL, templateId: String, resumeFrom: Int64) async throws -> (URL, Int64) {
        let partialPath = partialDownloadPath(for: templateId)
        let finalPath = downloadsDirectory.appendingPathComponent("\(templateId).tar.zst")
        
        // Determine actual resume position from file size
        var resumePosition: Int64 = 0
        if resumeFrom > 0 && fileManager.fileExists(atPath: partialPath.path) {
            let attrs = try? fileManager.attributesOfItem(atPath: partialPath.path)
            resumePosition = (attrs?[.size] as? Int64) ?? 0
        }
        
        // Save initial state for resume capability (size will be updated from server)
        let initialState = DownloadState(
            templateId: templateId,
            url: url.absoluteString,
            expectedSize: 0,  // Will be updated from Content-Length
            partialFilePath: partialPath.path,
            bytesDownloaded: resumePosition,
            startedAt: Date()
        )
        saveDownloadState(initialState)
        
        // Track the actual size from server and speed for time estimate
        var actualTotalSize: Int64 = 0
        var lastBytes: Int64 = resumePosition
        var lastTime = Date()
        var speedSamples: [Double] = []  // Rolling average of speed samples
        let maxSpeedSamples = 10
        
        // Use the efficient delegate-based downloader
        let downloader = ResumableDownloader(
            url: url,
            destinationPath: partialPath,
            resumeFrom: resumePosition,
            expectedSize: 0,  // Will be determined from Content-Length
            templateId: templateId,
            onProgress: { [weak self] bytesWritten, totalBytes in
                actualTotalSize = totalBytes
                
                // Calculate speed and time estimate
                let now = Date()
                let elapsed = now.timeIntervalSince(lastTime)
                let bytesInInterval = bytesWritten - lastBytes
                
                var estimatedTime: TimeInterval? = nil
                if elapsed > 0 && bytesInInterval > 0 {
                    let currentSpeed = Double(bytesInInterval) / elapsed  // bytes per second
                    speedSamples.append(currentSpeed)
                    if speedSamples.count > maxSpeedSamples {
                        speedSamples.removeFirst()
                    }
                    
                    // Use average speed for smoother estimate
                    let avgSpeed = speedSamples.reduce(0, +) / Double(speedSamples.count)
                    if avgSpeed > 0 {
                        let remainingBytes = totalBytes - bytesWritten
                        estimatedTime = Double(remainingBytes) / avgSpeed
                    }
                    
                    lastBytes = bytesWritten
                    lastTime = now
                }
                
                Task { @MainActor in
                    self?.progress = TemplateDownloadProgress(
                        phase: .downloading,
                        bytesDownloaded: bytesWritten,
                        totalBytes: totalBytes,
                        estimatedTimeRemaining: estimatedTime
                    )
                }
            },
            onStateUpdate: { [weak self] bytesWritten in
                let state = DownloadState(
                    templateId: templateId,
                    url: url.absoluteString,
                    expectedSize: actualTotalSize,
                    partialFilePath: partialPath.path,
                    bytesDownloaded: bytesWritten,
                    startedAt: initialState.startedAt
                )
                self?.saveDownloadState(state)
            }
        )
        
        do {
            let finalBytes = try await downloader.download()
            
            // Log download completion
            print("Download complete: \(finalBytes) bytes")
            
            // Rename partial to final
            try? fileManager.removeItem(at: finalPath)
            try fileManager.moveItem(at: partialPath, to: finalPath)
            
            return (finalPath, finalBytes)
            
        } catch is CancellationError {
            // Save state before throwing
            if let attrs = try? fileManager.attributesOfItem(atPath: partialPath.path),
               let size = attrs[.size] as? Int64 {
                let state = DownloadState(
                    templateId: templateId,
                    url: url.absoluteString,
                    expectedSize: actualTotalSize,
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
                    expectedSize: actualTotalSize,
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
    /// Stream decompress .tar.zst and extract directly to templates directory
    /// This eliminates the ~70GB intermediate .tar file, saving disk space and I/O
    private func decompressAndExtract(_ sourcePath: URL, templateId: String, compressedSize: Int64, onProgress: @escaping (Int64) -> Void, onExtracting: @escaping () -> Void = {}) async throws -> URL {
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
            
            // Connect pipe read end to tar's stdin
            let pipeReadHandle = FileHandle(fileDescriptor: pipeReadFD, closeOnDealloc: false)
            tarProcess.standardInput = pipeReadHandle
            
            let errorPipe = Pipe()
            tarProcess.standardError = errorPipe
            
            try tarProcess.run()
            
            // Close read end in parent (tar owns it now via FileHandle)
            close(pipeReadFD)
            
            // Decompress and write to pipe in a separate context
            var decompressionError: Error?
            
            do {
                // Use streaming decompression
                let dctx = ZSTD_createDCtx()
                guard dctx != nil else {
                    throw TemplateDownloadError.decompressionFailed("Failed to create decompression context")
                }
                defer { ZSTD_freeDCtx(dctx) }
                
                // Open compressed input file
                let inputFD = open(sourcePath.path, O_RDONLY)
                guard inputFD >= 0 else {
                    throw TemplateDownloadError.decompressionFailed("Cannot open compressed file")
                }
                defer { close(inputFD) }
                
                // Buffer sizes - use recommended sizes from zstd
                let inputBufferSize = ZSTD_DStreamInSize()
                let outputBufferSize = ZSTD_DStreamOutSize()
                
                // Allocate buffers directly (minimal memory overhead)
                let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: inputBufferSize)
                let outputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: outputBufferSize)
                defer {
                    inputBuffer.deallocate()
                    outputBuffer.deallocate()
                }
                
                // Track progress
                var totalBytesRead: Int64 = 0
                var lastProgressUpdate = Date()
                
                // Stream decompress and pipe to tar
                while true {
                    let bytesRead = read(inputFD, inputBuffer, inputBufferSize)
                    if bytesRead <= 0 {
                        break
                    }
                    
                    totalBytesRead += Int64(bytesRead)
                    
                    // Update progress every 500ms
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
                            // Write decompressed data directly to pipe (feeds tar)
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
                
                // Final progress update - decompression complete
                onProgress(compressedSize)
            } catch {
                decompressionError = error
            }
            
            // Close write end of pipe to signal EOF to tar
            close(pipeWriteFD)
            
            // Signal that we're now in extraction phase
            onExtracting()
            
            // Wait for tar to finish extracting
            // Note: This may take time as tar writes files to disk
            tarProcess.waitUntilExit()
            
            // Check for errors
            if let error = decompressionError {
                throw error
            }
            
            if tarProcess.terminationStatus != 0 {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                throw TemplateDownloadError.extractionFailed("tar failed: \(errorMessage)")
            }
            
            // Check for the expected template path
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

