//
//  DeviceSessionManager.swift
//  HivecrewAPI
//
//  Manages device pairing, session tokens, and authorized device persistence
//

import Foundation
import CryptoKit
import Security
import Logging

/// Actor that manages all device pairing and session state
public actor DeviceSessionManager {
    
    /// In-memory pending pairing requests (keyed by pairing ID)
    var pendingPairings: [String: APIPairingRequest] = [:]
    
    /// Persisted authorized device sessions
    var authorizedDevices: [APIDeviceSession] = []
    
    /// HMAC signing key for session tokens
    let signingKey: SymmetricKey
    
    /// Session max age in seconds
    let sessionMaxAge: TimeInterval
    
    /// File URL for persisting device sessions
    let storageURL: URL
    
    /// Delegate for notifying the host app
    weak var delegate: (any DeviceAuthDelegate)?
    
    /// Logger
    let logger: Logger
    
    /// Cleanup task
    var cleanupTask: Task<Void, Never>?
    
    // MARK: - Initialization
    
    public init(
        signingKeyData: Data? = nil,
        sessionMaxAgeDays: Int = 180,
        storageDirectory: URL? = nil
    ) {
        // Use provided key or generate a new one
        if let keyData = signingKeyData {
            self.signingKey = SymmetricKey(data: keyData)
        } else {
            self.signingKey = SymmetricKey(size: .bits256)
        }
        
        self.sessionMaxAge = TimeInterval(sessionMaxAgeDays * 24 * 3600)
        
        // Storage path
        let storageDir = storageDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Hivecrew", isDirectory: true)
        
        self.storageURL = storageDir.appendingPathComponent("authorized_devices.json")
        
        var logger = Logger(label: "com.pattonium.device-auth")
        logger.logLevel = .info
        self.logger = logger
    }
    
    /// Load persisted devices and start cleanup timer. Call after init.
    public func start() {
        loadDevices()
        startCleanupTimer()
    }
    
    /// Set the delegate for pairing notifications
    public func setDelegate(_ delegate: any DeviceAuthDelegate) {
        self.delegate = delegate
        // Send current devices to delegate
        let devices = authorizedDevices
        Task { @MainActor in
            delegate.devicesChanged(devices)
        }
    }
    
    /// Export the signing key data for Keychain storage
    public var signingKeyData: Data {
        signingKey.withUnsafeBytes { Data($0) }
    }
    
    // MARK: - Pairing Lifecycle
    
    /// Create a new pairing request. Returns the pairing ID and 6-digit code.
    public func createPairing(userAgent: String) -> (pairingId: String, code: String) {
        // Clean up expired pairings
        cleanupExpiredPairings()
        
        let pairingId = generatePairingId()
        let code = generatePairingCode()
        let deviceInfo = APIDeviceInfo.from(userAgent: userAgent)
        
        let request = APIPairingRequest(
            id: pairingId,
            code: code,
            deviceInfo: deviceInfo,
            userAgent: userAgent
        )
        
        pendingPairings[pairingId] = request
        
        logger.info("Pairing request created: \(pairingId) code=\(code) device=\(deviceInfo.displayName)")
        
        // Notify delegate
        let delegate = self.delegate
        let req = request
        Task { @MainActor in
            delegate?.pairingRequested(req)
        }
        
        return (pairingId, code)
    }
    
    /// Get the status of a pairing request
    public func getPairingStatus(pairingId: String) -> APIPairingRequest? {
        guard var request = pendingPairings[pairingId] else { return nil }
        
        // Check expiry
        if request.isExpired && request.status == .pending {
            request.status = .expired
            pendingPairings[pairingId] = request
        }
        
        return request
    }
    
    /// Approve a pairing request. Returns the session token to set as a cookie.
    /// - Parameters:
    ///   - id: The pairing request ID
    ///   - customName: Optional custom name for the device. Falls back to the auto-detected display name.
    public func approvePairing(id: String, customName: String? = nil) -> String? {
        guard var request = pendingPairings[id], request.status == .pending, !request.isExpired else {
            logger.warning("Cannot approve pairing \(id): not found, not pending, or expired")
            return nil
        }
        
        // Generate device ID and session token
        let deviceId = UUID().uuidString
        let sessionToken = generateSessionToken(deviceId: deviceId)
        let tokenHash = hashToken(sessionToken)
        
        // Create device session
        let now = Date()
        let deviceName = (customName?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap({ $0.isEmpty ? nil : $0 }) ?? request.deviceInfo.displayName
        let device = APIDeviceSession(
            id: deviceId,
            name: deviceName,
            deviceType: request.deviceInfo.deviceType,
            browser: request.deviceInfo.browser,
            os: request.deviceInfo.os,
            authorizedAt: now,
            lastSeenAt: now,
            sessionTokenHash: tokenHash
        )
        
        // Update pairing request
        request.status = .approved
        request.sessionToken = sessionToken
        request.deviceId = deviceId
        pendingPairings[id] = request
        
        // Add to authorized devices
        authorizedDevices.append(device)
        saveDevices()
        notifyDevicesChanged()
        
        logger.info("Pairing approved: \(id) -> device \(deviceId) (\(device.name))")
        
        // Clean up the pairing after a short delay (let the browser poll pick it up)
        Task {
            try? await Task.sleep(for: .seconds(30))
            await self.removePairing(id: id)
        }
        
        return sessionToken
    }
    
    /// Reject a pairing request
    public func rejectPairing(id: String) {
        guard var request = pendingPairings[id], request.status == .pending else { return }
        request.status = .rejected
        pendingPairings[id] = request
        logger.info("Pairing rejected: \(id)")
        
        // Clean up after a short delay
        Task {
            try? await Task.sleep(for: .seconds(10))
            await self.removePairing(id: id)
        }
    }
    
    /// Remove a pairing request from memory
    private func removePairing(id: String) {
        pendingPairings.removeValue(forKey: id)
    }
    
    /// Get all pending pairing requests (for the macOS app UI)
    public func getPendingPairings() -> [APIPairingRequest] {
        cleanupExpiredPairings()
        return Array(pendingPairings.values.filter { $0.status == .pending && !$0.isExpired })
    }
    
    // MARK: - Session Validation
    
    /// Validate a session token from a cookie. Returns the device session if valid.
    public func validateSession(token: String) -> APIDeviceSession? {
        // Verify the HMAC signature and extract the device ID
        guard let deviceId = verifySessionToken(token) else { return nil }
        
        // Find the device in authorized list
        guard let index = authorizedDevices.firstIndex(where: { $0.id == deviceId }) else {
            return nil
        }
        
        // Verify the token hash matches
        let tokenHash = hashToken(token)
        guard authorizedDevices[index].sessionTokenHash == tokenHash else {
            return nil
        }
        
        return authorizedDevices[index]
    }
    
    /// Update the lastSeenAt timestamp for a device
    public func updateLastSeen(deviceId: String) {
        guard let index = authorizedDevices.firstIndex(where: { $0.id == deviceId }) else { return }
        authorizedDevices[index].lastSeenAt = Date()
        // Debounce saves — only write periodically
        saveDevices()
    }
    
    // MARK: - Device Management
    
    /// List all authorized devices
    public func listDevices() -> [APIDeviceSession] {
        authorizedDevices
    }
    
    /// Rename an authorized device
    public func renameDevice(id: String, name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = authorizedDevices.firstIndex(where: { $0.id == id }) else {
            return false
        }
        authorizedDevices[index].name = trimmed
        saveDevices()
        notifyDevicesChanged()
        logger.info("Device renamed: \(id) -> \(trimmed)")
        return true
    }
    
    /// Revoke (remove) an authorized device by ID
    public func revokeDevice(id: String) -> Bool {
        guard let index = authorizedDevices.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let device = authorizedDevices.remove(at: index)
        saveDevices()
        notifyDevicesChanged()
        logger.info("Device revoked: \(id) (\(device.name))")
        return true
    }
    
    /// Revoke a device by its session token
    public func revokeDeviceByToken(token: String) -> Bool {
        let tokenHash = hashToken(token)
        guard let index = authorizedDevices.firstIndex(where: { $0.sessionTokenHash == tokenHash }) else {
            return false
        }
        let device = authorizedDevices.remove(at: index)
        saveDevices()
        notifyDevicesChanged()
        logger.info("Device revoked by token: \(device.id) (\(device.name))")
        return true
    }
    
}
