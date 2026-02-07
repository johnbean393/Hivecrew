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
    public static let goldenV0013 = RemoteTemplate(
        id: "golden-v0.0.13",
        name: "Hivecrew Golden Image",
        description: "Pre-configured macOS 26.2 VM with HivecrewGuestAgent installed",
        version: "0.0.13",
        url: URL(string: "https://templates.hivecrew.org/golden-v0.0.13.tar.zst")!
    )

    /// The golden template hosted on Cloudflare R2
    public static let goldenV0012 = RemoteTemplate(
        id: "golden-v0.0.12",
        name: "Hivecrew Golden Image",
        description: "Pre-configured macOS 26.2 VM with HivecrewGuestAgent installed",
        version: "0.0.12",
        url: URL(string: "https://templates.hivecrew.org/golden-v0.0.12.tar.zst")!
    )

    /// The golden template hosted on Cloudflare R2
    public static let goldenV0011 = RemoteTemplate(
        id: "golden-v0.0.11",
        name: "Hivecrew Golden Image",
        description: "Pre-configured macOS 26.2 VM with HivecrewGuestAgent installed",
        version: "0.0.11",
        url: URL(string: "https://templates.hivecrew.org/golden-v0.0.11.tar.zst")!
    )

    /// The golden template hosted on Cloudflare R2
    public static let goldenV0010 = RemoteTemplate(
        id: "golden-v0.0.10",
        name: "Hivecrew Golden Image",
        description: "Pre-configured macOS 26.2 VM with HivecrewGuestAgent installed",
        version: "0.0.10",
        url: URL(string: "https://templates.hivecrew.org/golden-v0.0.10.tar.zst")!
    )
    
    /// All available templates for download
    public static let all: [RemoteTemplate] = [
        goldenV0013,
        goldenV0012,
        goldenV0011,
        goldenV0010,
    ]

    /// The default/recommended template
    public static let `default` = goldenV0013
    
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
