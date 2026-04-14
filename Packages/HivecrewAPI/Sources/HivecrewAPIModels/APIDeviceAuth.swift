//
//  APIDeviceAuth.swift
//  HivecrewAPI
//
//  Models for device authorization (PIN pairing) authentication
//

import Foundation

// MARK: - Device Type

/// Type of device connecting to the web UI
public enum APIDeviceType: String, Codable, Sendable {
    case desktop
    case mobile
    case tablet
    
    /// Parse device type from a User-Agent string
    public static func from(userAgent: String) -> APIDeviceType {
        let ua = userAgent.lowercased()
        if ua.contains("ipad") { return .tablet }
        if ua.contains("iphone") || ua.contains("android") && !ua.contains("tablet") {
            return .mobile
        }
        return .desktop
    }
}

// MARK: - Device Info

/// Parsed device information from User-Agent
public struct APIDeviceInfo: Codable, Sendable {
    public let browser: String
    public let os: String
    public let deviceType: APIDeviceType
    
    /// Human-readable display name (e.g. "Safari on iOS")
    public var displayName: String {
        "\(browser) on \(os)"
    }
    
    public init(browser: String, os: String, deviceType: APIDeviceType) {
        self.browser = browser
        self.os = os
        self.deviceType = deviceType
    }
    
    /// Parse device info from a User-Agent string
    public static func from(userAgent: String) -> APIDeviceInfo {
        let browser = parseBrowser(from: userAgent)
        let os = parseOS(from: userAgent)
        let deviceType = APIDeviceType.from(userAgent: userAgent)
        return APIDeviceInfo(browser: browser, os: os, deviceType: deviceType)
    }
    
    private static func parseBrowser(from userAgent: String) -> String {
        // Order matters: check more specific before generic
        if userAgent.contains("Edg/") || userAgent.contains("Edge/") { return "Edge" }
        if userAgent.contains("OPR/") || userAgent.contains("Opera") { return "Opera" }
        if userAgent.contains("Chrome/") && !userAgent.contains("Edg/") { return "Chrome" }
        if userAgent.contains("Firefox/") { return "Firefox" }
        if userAgent.contains("Safari/") && !userAgent.contains("Chrome/") { return "Safari" }
        return "Browser"
    }
    
    private static func parseOS(from userAgent: String) -> String {
        let ua = userAgent.lowercased()
        if ua.contains("iphone") { return "iOS" }
        if ua.contains("ipad") { return "iPadOS" }
        if ua.contains("mac os") || ua.contains("macintosh") { return "macOS" }
        if ua.contains("windows") { return "Windows" }
        if ua.contains("android") { return "Android" }
        if ua.contains("linux") { return "Linux" }
        if ua.contains("cros") { return "ChromeOS" }
        return "Unknown"
    }
}

// MARK: - Pairing Status

/// Status of an in-flight pairing request
public enum APIPairingStatus: String, Codable, Sendable {
    case pending
    case approved
    case rejected
    case expired
}

// MARK: - Pairing Request

/// An in-flight device pairing request (ephemeral, in-memory)
public struct APIPairingRequest: Sendable {
    public let id: String
    public let code: String
    public let deviceInfo: APIDeviceInfo
    public let userAgent: String
    public var status: APIPairingStatus
    public let createdAt: Date
    
    /// The session token, set when approved
    public var sessionToken: String?
    /// The device ID, set when approved
    public var deviceId: String?
    
    public var isExpired: Bool {
        Date().timeIntervalSince(createdAt) > 300 // 5 minutes
    }
    
    public init(id: String, code: String, deviceInfo: APIDeviceInfo, userAgent: String) {
        self.id = id
        self.code = code
        self.deviceInfo = deviceInfo
        self.userAgent = userAgent
        self.status = .pending
        self.createdAt = Date()
    }
}

// MARK: - Device Session (Persisted)

/// An authorized device session, persisted to disk
public struct APIDeviceSession: Codable, Sendable, Identifiable {
    public let id: String
    public var name: String
    public let deviceType: APIDeviceType
    public let browser: String
    public let os: String
    public let authorizedAt: Date
    public var lastSeenAt: Date
    /// Hash of the session token for validation
    public let sessionTokenHash: String
    
    public init(
        id: String,
        name: String,
        deviceType: APIDeviceType,
        browser: String,
        os: String,
        authorizedAt: Date,
        lastSeenAt: Date,
        sessionTokenHash: String
    ) {
        self.id = id
        self.name = name
        self.deviceType = deviceType
        self.browser = browser
        self.os = os
        self.authorizedAt = authorizedAt
        self.lastSeenAt = lastSeenAt
        self.sessionTokenHash = sessionTokenHash
    }
}

// MARK: - Request / Response DTOs

/// Response for POST /api/v1/auth/pair/request
public struct PairingRequestResponse: Codable, Sendable {
    public let pairingId: String
    public let code: String
    public let expiresIn: Int // seconds
    
    public init(pairingId: String, code: String, expiresIn: Int = 300) {
        self.pairingId = pairingId
        self.code = code
        self.expiresIn = expiresIn
    }
}

/// Response for GET /api/v1/auth/pair/status
public struct PairingStatusResponse: Codable, Sendable {
    public let status: APIPairingStatus
    public let deviceName: String?
    
    public init(status: APIPairingStatus, deviceName: String? = nil) {
        self.status = status
        self.deviceName = deviceName
    }
}

/// Response for GET /api/v1/auth/devices
public struct DeviceListResponse: Codable, Sendable {
    public let devices: [DeviceResponse]
    
    public init(devices: [DeviceResponse]) {
        self.devices = devices
    }
}

/// Individual device in a device list response (omits token hash)
public struct DeviceResponse: Codable, Sendable {
    public let id: String
    public let name: String
    public let deviceType: APIDeviceType
    public let browser: String
    public let os: String
    public let authorizedAt: Date
    public let lastSeenAt: Date
    
    public init(from session: APIDeviceSession) {
        self.id = session.id
        self.name = session.name
        self.deviceType = session.deviceType
        self.browser = session.browser
        self.os = session.os
        self.authorizedAt = session.authorizedAt
        self.lastSeenAt = session.lastSeenAt
    }
}

/// Response for GET /api/v1/auth/check
public struct AuthCheckResponse: Codable, Sendable {
    public let authenticated: Bool
    public let method: String? // "cookie", "bearer", or nil
    
    public init(authenticated: Bool, method: String? = nil) {
        self.authenticated = authenticated
        self.method = method
    }
}
