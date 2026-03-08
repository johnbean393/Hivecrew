//
//  DeviceSessionManager+Tokens.swift
//  HivecrewAPI
//
//  Token and pairing identifier generation for device auth sessions
//

import CryptoKit
import Foundation
import Security

extension DeviceSessionManager {
    /// Generate a signed session token encoding the device ID and expiry
    func generateSessionToken(deviceId: String) -> String {
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
    func verifySessionToken(_ token: String) -> String? {
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
    func hashToken(_ token: String) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Generate a cryptographically random 6-digit pairing code
    func generatePairingCode() -> String {
        var bytes = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let value = (UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])) % 1_000_000
        return String(format: "%06d", value)
    }

    /// Generate a unique pairing request ID
    func generatePairingId() -> String {
        UUID().uuidString.lowercased()
    }
}
