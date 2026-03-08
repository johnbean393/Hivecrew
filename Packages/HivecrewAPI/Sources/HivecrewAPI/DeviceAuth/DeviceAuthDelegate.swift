//
//  DeviceAuthDelegate.swift
//  HivecrewAPI
//
//  Host callbacks for device pairing and authorized device updates
//

import Foundation

/// Protocol for notifying the host app about pairing requests
public protocol DeviceAuthDelegate: AnyObject, Sendable {
    /// Called when a new device pairing request is created
    @MainActor func pairingRequested(_ request: APIPairingRequest)

    /// Called when the list of authorized devices changes
    @MainActor func devicesChanged(_ devices: [APIDeviceSession])
}
