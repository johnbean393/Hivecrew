//
//  TemplateDownloadModels.swift
//  Hivecrew
//
//  Models and types for template downloads
//

import Combine
import Foundation

/// Configuration for remote template downloads
public struct RemoteTemplate: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let version: String
    public let url: URL
    public let sizeBytes: Int64?  // Optional - will be fetched from server if not provided
    public let installedSizeBytes: Int64?
    public let sha256: String?
    
    public init(
        id: String,
        name: String,
        description: String,
        version: String,
        url: URL,
        sizeBytes: Int64? = nil,
        installedSizeBytes: Int64? = nil,
        sha256: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.version = version
        self.url = url
        self.sizeBytes = sizeBytes
        self.installedSizeBytes = installedSizeBytes
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
    
    public static let goldenV0020 = RemoteTemplate(
        id: "golden-v0.0.20",
        name: "Hivecrew Golden Image",
        description: "Pre-configured macOS 26.2 VM with HivecrewGuestAgent installed",
        version: "0.0.20",
        url: URL(string: "https://templates.hivecrew.org/golden-v0.0.20.tar.zst")!
    )

    public static let goldenV0019 = RemoteTemplate(
        id: "golden-v0.0.19",
        name: "Hivecrew Golden Image",
        description: "Pre-configured macOS 26.2 VM with HivecrewGuestAgent installed",
        version: "0.0.19",
        url: URL(string: "https://templates.hivecrew.org/golden-v0.0.19.tar.zst")!
    )
    
    public static let goldenV0018 = RemoteTemplate(
        id: "golden-v0.0.18",
        name: "Hivecrew Golden Image",
        description: "Pre-configured macOS 26.2 VM with HivecrewGuestAgent installed",
        version: "0.0.18",
        url: URL(string: "https://templates.hivecrew.org/golden-v0.0.18.tar.zst")!
    )
    
    /// All available templates for download
    public static let all: [RemoteTemplate] = [
        goldenV0020,
        goldenV0019,
        goldenV0018
    ]

    /// The default/recommended template
    public static let `default`: RemoteTemplate = goldenV0020
    
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
        public let sizeBytes: Int64?
        public let installedSizeBytes: Int64?
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
                url: url,
                sizeBytes: sizeBytes,
                installedSizeBytes: installedSizeBytes
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
            return String(localized: "Downloading template...")
        case .decompressing:
            return String(localized: "Decompressing...")
        case .extracting:
            return String(localized: "Extracting files...")
        case .configuring:
            return String(localized: "Configuring template...")
        case .complete:
            return String(localized: "Complete")
        case .failed(let error):
            return String(localized: "Failed: \(error)")
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
    case insufficientStorage(requiredBytes: Int64?, availableBytes: Int64?)
    case invalidTemplate(String)
    case fileSystemError(String)
    
    public var errorDescription: String? {
        switch self {
        case .downloadFailed(let message):
            return String(localized: "Download failed: \(message)")
        case .decompressionFailed(let message):
            return String(localized: "Decompression failed: \(message)")
        case .extractionFailed(let message):
            return String(localized: "Extraction failed: \(message)")
        case .configurationFailed(let message):
            return String(localized: "Configuration failed: \(message)")
        case .cancelled:
            return String(localized: "Download was cancelled")
        case .insufficientStorage(let requiredBytes, let availableBytes):
            if let requiredBytes, let availableBytes, requiredBytes > 0, availableBytes >= 0 {
                let formatter = ByteCountFormatter()
                formatter.allowedUnits = [.useGB, .useMB]
                formatter.countStyle = .file
                formatter.includesUnit = true

                let requiredString = formatter.string(fromByteCount: requiredBytes)
                let availableString = formatter.string(fromByteCount: availableBytes)
                return "Not enough free disk space to complete the template update. Hivecrew needs about \(requiredString) free on this volume, but macOS is currently reporting only \(availableString) immediately writable."
            }
            return String(localized: "Not enough free disk space to complete the template update")
        case .invalidTemplate(let message):
            return String(localized: "Invalid template: \(message)")
        case .fileSystemError(let message):
            return String(localized: "File system error: \(message)")
        }
    }
}

/// Persistent state for resumable downloads
struct DownloadState: Codable {
    let templateId: String
    let url: String
    let expectedSize: Int64
    let partialFilePath: String
    let bytesDownloaded: Int64
    let startedAt: Date
}

func isTemplateDownloadOutOfSpaceError(_ error: Error) -> Bool {
    if let downloadError = error as? TemplateDownloadError,
       case .insufficientStorage = downloadError {
        return true
    }
    
    let nsError = error as NSError
    
    if nsError.domain == NSCocoaErrorDomain,
       nsError.code == CocoaError.Code.fileWriteOutOfSpace.rawValue {
        return true
    }
    
    if nsError.domain == NSPOSIXErrorDomain,
       nsError.code == ENOSPC {
        return true
    }
    
    if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
        return isTemplateDownloadOutOfSpaceError(underlying)
    }
    
    return false
}

func normalizeTemplateDownloadError(_ error: Error) -> Error {
    if isTemplateDownloadOutOfSpaceError(error) {
        return TemplateDownloadError.insufficientStorage(requiredBytes: nil, availableBytes: nil)
    }
    
    return error
}
