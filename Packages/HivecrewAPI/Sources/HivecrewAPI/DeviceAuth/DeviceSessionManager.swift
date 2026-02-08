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

// MARK: - Delegate Protocol

/// Protocol for notifying the host app about pairing requests
public protocol DeviceAuthDelegate: AnyObject, Sendable {
    /// Called when a new device pairing request is created
    @MainActor func pairingRequested(_ request: APIPairingRequest)
    /// Called when the list of authorized devices changes
    @MainActor func devicesChanged(_ devices: [APIDeviceSession])
}

// MARK: - Device Session Manager

/// Actor that manages all device pairing and session state
public actor DeviceSessionManager {
    
    /// In-memory pending pairing requests (keyed by pairing ID)
    private var pendingPairings: [String: APIPairingRequest] = [:]
    
    /// Persisted authorized device sessions
    private var authorizedDevices: [APIDeviceSession] = []
    
    /// HMAC signing key for session tokens
    private let signingKey: SymmetricKey
    
    /// Session max age in seconds
    private let sessionMaxAge: TimeInterval
    
    /// File URL for persisting device sessions
    private let storageURL: URL
    
    /// Delegate for notifying the host app
    private weak var delegate: (any DeviceAuthDelegate)?
    
    /// Logger
    private let logger: Logger
    
    /// Cleanup task
    private var cleanupTask: Task<Void, Never>?
    
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
    
    // MARK: - Token Generation & Verification
    
    /// Generate a signed session token encoding the device ID and expiry
    private func generateSessionToken(deviceId: String) -> String {
        let expiry = Date().addingTimeInterval(sessionMaxAge)
        let expiryTimestamp = Int(expiry.timeIntervalSince1970)
        let payload = "\(deviceId).\(expiryTimestamp)"
        let payloadData = Data(payload.utf8)
        
        let signature = HMAC<SHA256>.authenticationCode(for: payloadData, using: signingKey)
        let signatureHex = signature.map { String(format: "%02x", $0) }.joined()
        
        // Token format: base64(payload).signature
        let payloadBase64 = payloadData.base64EncodedString()
        return "\(payloadBase64).\(signatureHex)"
    }
    
    /// Verify a session token and return the device ID if valid
    private func verifySessionToken(_ token: String) -> String? {
        let parts = token.split(separator: ".", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        
        let payloadBase64 = String(parts[0])
        let signatureHex = String(parts[1])
        
        // Decode payload
        guard let payloadData = Data(base64Encoded: payloadBase64),
              let payload = String(data: payloadData, encoding: .utf8) else {
            return nil
        }
        
        // Verify HMAC
        let expectedSignature = HMAC<SHA256>.authenticationCode(for: payloadData, using: signingKey)
        let expectedHex = expectedSignature.map { String(format: "%02x", $0) }.joined()
        
        guard signatureHex == expectedHex else { return nil }
        
        // Parse payload: deviceId.expiryTimestamp
        let payloadParts = payload.split(separator: ".", maxSplits: 1)
        guard payloadParts.count == 2,
              let expiryTimestamp = Int(payloadParts[1]) else {
            return nil
        }
        
        // Check expiry
        let expiry = Date(timeIntervalSince1970: TimeInterval(expiryTimestamp))
        guard expiry > Date() else { return nil }
        
        return String(payloadParts[0])
    }
    
    /// SHA-256 hash of a token for storage (we never store raw tokens)
    private func hashToken(_ token: String) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    
    // MARK: - Code & ID Generation
    
    /// Generate a cryptographically random 6-digit pairing code
    private func generatePairingCode() -> String {
        var bytes = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let value = (UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])) % 1_000_000
        return String(format: "%06d", value)
    }
    
    /// Generate a unique pairing request ID
    private func generatePairingId() -> String {
        UUID().uuidString.lowercased()
    }
    
    // MARK: - Persistence
    
    /// Load authorized devices from disk
    private func loadDevices() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            logger.info("No device storage file found, starting fresh")
            return
        }
        
        do {
            let data = try Data(contentsOf: storageURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            authorizedDevices = try decoder.decode([APIDeviceSession].self, from: data)
            logger.info("Loaded \(authorizedDevices.count) authorized device(s)")
        } catch {
            logger.error("Failed to load authorized devices: \(error)")
        }
    }
    
    /// Save authorized devices to disk
    private func saveDevices() {
        do {
            // Ensure directory exists
            let directory = storageURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(authorizedDevices)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            logger.error("Failed to save authorized devices: \(error)")
        }
    }
    
    // MARK: - Cleanup
    
    /// Remove expired pairing requests from memory
    private func cleanupExpiredPairings() {
        let now = Date()
        
        // Mark pending pairings as expired if past TTL
        let expired = pendingPairings.filter { $0.value.isExpired && $0.value.status == .pending }
        for (id, _) in expired {
            pendingPairings[id]?.status = .expired
        }
        
        // Remove rejected/expired pairings older than 5 minutes
        // Approved pairings are cleaned up by their own scheduled Task (30s after approval)
        pendingPairings = pendingPairings.filter { _, request in
            switch request.status {
            case .pending, .approved:
                return true
            case .rejected, .expired:
                return now.timeIntervalSince(request.createdAt) < 300
            }
        }
    }
    
    /// Start periodic cleanup of expired pairings
    private func startCleanupTimer() {
        cleanupTask?.cancel()
        cleanupTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.cleanupExpiredPairings()
            }
        }
    }
    
    // MARK: - Delegate Notification
    
    private func notifyDevicesChanged() {
        let devices = authorizedDevices
        let delegate = self.delegate
        Task { @MainActor in
            delegate?.devicesChanged(devices)
        }
    }
}
