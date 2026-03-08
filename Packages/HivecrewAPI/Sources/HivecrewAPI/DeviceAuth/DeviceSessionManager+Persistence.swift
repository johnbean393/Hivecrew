//
//  DeviceSessionManager+Persistence.swift
//  HivecrewAPI
//
//  Persistence, cleanup, and delegate notifications for device auth sessions
//

import Foundation

extension DeviceSessionManager {
    /// Load authorized devices from disk
    func loadDevices() {
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
    func saveDevices() {
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

    /// Remove expired pairing requests from memory
    func cleanupExpiredPairings() {
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
    func startCleanupTimer() {
        cleanupTask?.cancel()
        cleanupTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.cleanupExpiredPairings()
            }
        }
    }

    func notifyDevicesChanged() {
        let devices = authorizedDevices
        let delegate = self.delegate
        Task { @MainActor in
            delegate?.devicesChanged(devices)
        }
    }
}
