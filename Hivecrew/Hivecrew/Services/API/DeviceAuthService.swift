//
//  DeviceAuthService.swift
//  Hivecrew
//
//  Bridges device pairing notifications from the API server to SwiftUI
//

import Combine
import Foundation
import HivecrewAPI

/// Manages device authorization UI state and bridges to DeviceSessionManager
@MainActor
final class DeviceAuthService: ObservableObject, DeviceAuthDelegate {
    
    /// Shared singleton
    static let shared = DeviceAuthService()
    
    // MARK: - Published State
    
    /// Pending pairing requests awaiting user approval
    @Published var pendingPairings: [APIPairingRequest] = []
    
    /// All currently authorized devices
    @Published var authorizedDevices: [APIDeviceSession] = []
    
    // MARK: - Internal State
    
    /// Reference to the server's session manager
    private var sessionManager: DeviceSessionManager?
    
    private init() {}
    
    // MARK: - Configuration
    
    /// Set the session manager reference (called during server startup)
    func configure(with manager: DeviceSessionManager) {
        self.sessionManager = manager
    }
    
    /// Clear the session manager reference (called during server shutdown)
    func unconfigure() {
        self.sessionManager = nil
        self.pendingPairings = []
    }
    
    // MARK: - DeviceAuthDelegate
    
    func pairingRequested(_ request: APIPairingRequest) {
        // Add to pending list (avoid duplicates)
        if !pendingPairings.contains(where: { $0.id == request.id }) {
            pendingPairings.append(request)
        }
        
        // Show the floating pairing approval window
        PairingWindowController.shared.showPairingRequest(request)
    }
    
    func devicesChanged(_ devices: [APIDeviceSession]) {
        authorizedDevices = devices
    }
    
    // MARK: - User Actions
    
    /// Approve a pending pairing request, optionally with a custom device name
    func approvePairing(id: String, customName: String? = nil) async {
        guard let manager = sessionManager else { return }
        
        _ = await manager.approvePairing(id: id, customName: customName)
        
        // Remove from pending list
        pendingPairings.removeAll { $0.id == id }
        
        // Refresh device list
        let devices = await manager.listDevices()
        authorizedDevices = devices
    }
    
    /// Reject a pending pairing request
    func rejectPairing(id: String) async {
        guard let manager = sessionManager else { return }
        
        await manager.rejectPairing(id: id)
        
        // Remove from pending list
        pendingPairings.removeAll { $0.id == id }
    }
    
    /// Rename an authorized device
    func renameDevice(id: String, name: String) async {
        guard let manager = sessionManager else { return }
        
        _ = await manager.renameDevice(id: id, name: name)
        
        // Refresh device list
        let devices = await manager.listDevices()
        authorizedDevices = devices
    }
    
    /// Revoke an authorized device
    func revokeDevice(id: String) async {
        guard let manager = sessionManager else { return }
        
        _ = await manager.revokeDevice(id: id)
        
        // Refresh device list
        let devices = await manager.listDevices()
        authorizedDevices = devices
    }
    
    /// Refresh the list of authorized devices from the session manager
    func refreshDevices() async {
        guard let manager = sessionManager else { return }
        
        let devices = await manager.listDevices()
        authorizedDevices = devices
        
        // Also refresh pending pairings
        let pending = await manager.getPendingPairings()
        pendingPairings = pending
    }
}
