//
//  RemoteAccessManager.swift
//  Hivecrew
//
//  Orchestrates remote access: auth, tunnel provisioning, cloudflared lifecycle, and heartbeat
//

import Combine
import Foundation
import SwiftUI

// MARK: - Remote Access State

/// Observable state for the remote access connection
@MainActor
final class RemoteAccessStatus: ObservableObject {
    static let shared = RemoteAccessStatus()
    
    @Published var state: RemoteAccessState = .notConfigured
    @Published var remoteURL: String?
    @Published var subdomain: String?
    @Published var email: String?
    @Published var errorMessage: String?
    
    private init() {}
    
    func update(
        state: RemoteAccessState,
        url: String? = nil,
        subdomain: String? = nil,
        email: String? = nil,
        error: String? = nil
    ) {
        self.state = state
        if let url { self.remoteURL = url }
        if let subdomain { self.subdomain = subdomain }
        if let email { self.email = email }
        self.errorMessage = error
    }
    
    func reset() {
        state = .notConfigured
        remoteURL = nil
        subdomain = nil
        email = nil
        errorMessage = nil
    }
}

enum RemoteAccessState: Equatable {
    case notConfigured
    case authenticating
    case awaitingOTP
    case provisioning
    case connecting
    case connected
    case disconnected
    case failed
}

// MARK: - Remote Access Manager

actor RemoteAccessManager {
    
    static let shared = RemoteAccessManager()

    private struct RemoteReconnectSnapshot {
        let enabled: Bool
        let isConfigured: Bool
        let email: String?
        let subdomain: String?
        let tunnelToken: String?
    }
    
    private let apiClient = RemoteAccessAPIClient()
    private let cloudflaredManager = CloudflaredManager()
    
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    
    private init() {}
    
    // MARK: - Setup Flow
    
    /// Step 1: Request OTP for the given email
    func requestOTP(email: String) async {
        await updateStatus(state: .authenticating, email: email)
        
        do {
            try await apiClient.register(email: email)
            await updateStatus(state: .awaitingOTP, email: email)
        } catch {
            await updateStatus(state: .failed, error: error.localizedDescription)
        }
    }
    
    /// Step 2: Verify OTP code
    func verifyOTP(email: String, code: String) async {
        await updateStatus(state: .authenticating)
        
        do {
            let sessionToken = try await apiClient.verify(email: email, code: code)
            
            // Store session token and email in Keychain
            RemoteAccessKeychain.storeSessionToken(sessionToken)
            RemoteAccessKeychain.storeEmail(email)
            
            // Proceed to create tunnel
            await createTunnel(sessionToken: sessionToken)
        } catch {
            await updateStatus(state: .awaitingOTP, error: error.localizedDescription)
        }
    }
    
    /// Step 3: Create tunnel via the Worker API
    private func createTunnel(sessionToken: String) async {
        await updateStatus(state: .provisioning)
        
        do {
            let response = try await apiClient.createTunnel(sessionToken: sessionToken)
            
            // Store tunnel credentials in Keychain
            RemoteAccessKeychain.storeTunnelToken(response.tunnelToken)
            RemoteAccessKeychain.storeSubdomain(response.subdomain)
            RemoteAccessKeychain.storeTunnelId(response.tunnelId)
            
            // Store in UserDefaults for quick access
            UserDefaults.standard.set(true, forKey: "remoteAccessEnabled")
            UserDefaults.standard.set(response.subdomain, forKey: "remoteAccessSubdomain")
            
            // Start cloudflared
            await startCloudflared(tunnelToken: response.tunnelToken, subdomain: response.subdomain)
        } catch {
            await updateStatus(state: .failed, error: error.localizedDescription)
        }
    }
    
    // MARK: - Connection Management
    
    /// Start cloudflared and connect the tunnel
    private func startCloudflared(tunnelToken: String, subdomain: String) async {
        await updateStatus(state: .connecting)
        
        // Set up crash handler
        await cloudflaredManager.setOnUnexpectedTermination { [weak self] code in
            guard let self else { return }
            Task {
                await self.handleCloudflaredCrash(code: code)
            }
        }
        
        do {
            try await cloudflaredManager.start(token: tunnelToken)
            
            let url = "https://\(subdomain).hivecrew.org"
            await updateStatus(state: .connected, url: url, subdomain: subdomain)
            
            // Start heartbeat
            startHeartbeat()
            
            print("RemoteAccessManager: Connected at \(url)")
        } catch {
            await updateStatus(state: .failed, error: error.localizedDescription)
        }
    }
    
    /// Reconnect using stored credentials
    func reconnect() async {
        let credentials = await loadReconnectSnapshot()
        guard let tunnelToken = credentials.tunnelToken,
              let subdomain = credentials.subdomain else {
            await updateStatus(state: .notConfigured, error: "No tunnel credentials found")
            return
        }
        
        await startCloudflared(tunnelToken: tunnelToken, subdomain: subdomain)
    }
    
    /// Auto-reconnect on startup if remote access was previously enabled
    func reconnectIfNeeded() async {
        let snapshot = await loadReconnectSnapshot()
        guard snapshot.enabled else { return }

        guard snapshot.isConfigured else {
            // Credentials were cleared but flag wasn't — clean up
            UserDefaults.standard.set(false, forKey: "remoteAccessEnabled")
            return
        }

        // Load stored info for display without blocking the main actor.
        await updateStatus(
            state: .disconnected,
            subdomain: snapshot.subdomain,
            email: snapshot.email
        )

        guard let tunnelToken = snapshot.tunnelToken,
              let subdomain = snapshot.subdomain else {
            await updateStatus(state: .notConfigured, error: "No tunnel credentials found")
            return
        }
        await startCloudflared(tunnelToken: tunnelToken, subdomain: subdomain)
    }
    
    /// Disconnect (stop cloudflared but keep credentials)
    func disconnect() async {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        
        await cloudflaredManager.stop()
        
        let snapshot = await loadReconnectSnapshot()
        await updateStatus(state: .disconnected, subdomain: snapshot.subdomain, email: snapshot.email)
    }
    
    /// Remove remote access completely (delete tunnel, clear credentials)
    func remove() async {
        // Stop cloudflared
        await disconnect()
        
        await updateStatus(state: .notConfigured)
        
        // Delete tunnel via Worker API
        if let sessionToken = RemoteAccessKeychain.retrieveSessionToken(),
           let tunnelId = RemoteAccessKeychain.retrieveTunnelId() {
            do {
                try await apiClient.deleteTunnel(tunnelId: tunnelId, sessionToken: sessionToken)
            } catch {
                print("RemoteAccessManager: Failed to delete tunnel on server: \(error)")
                // Continue with local cleanup anyway
            }
        }
        
        // Clear all local credentials
        RemoteAccessKeychain.clearAll()
        UserDefaults.standard.set(false, forKey: "remoteAccessEnabled")
        UserDefaults.standard.removeObject(forKey: "remoteAccessSubdomain")
        UserDefaults.standard.removeObject(forKey: "remoteAccessEmail")
        
        await resetStatus()
    }
    
    /// Graceful shutdown (called on app termination)
    func shutdown() async {
        heartbeatTask?.cancel()
        reconnectTask?.cancel()
        await cloudflaredManager.stop()
    }
    
    // MARK: - Heartbeat
    
    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task {
            while !Task.isCancelled {
                // Send heartbeat every 24 hours
                try? await Task.sleep(for: .seconds(24 * 60 * 60))
                
                guard !Task.isCancelled else { break }
                
                if let sessionToken = RemoteAccessKeychain.retrieveSessionToken(),
                   let tunnelId = RemoteAccessKeychain.retrieveTunnelId() {
                    do {
                        try await apiClient.heartbeat(tunnelId: tunnelId, sessionToken: sessionToken)
                        print("RemoteAccessManager: Heartbeat sent")
                    } catch {
                        print("RemoteAccessManager: Heartbeat failed: \(error)")
                    }
                }
            }
        }
    }
    
    // MARK: - Crash Recovery
    
    private func handleCloudflaredCrash(code: Int32) async {
        print("RemoteAccessManager: cloudflared crashed with code \(code)")

        let snapshot = await loadReconnectSnapshot()
        await updateStatus(
            state: .disconnected,
            subdomain: snapshot.subdomain,
            email: snapshot.email,
            error: "Tunnel disconnected unexpectedly (code \(code))"
        )
        
        // Auto-reconnect after a brief delay
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            
            print("RemoteAccessManager: Attempting auto-reconnect...")
            await self.reconnect()
        }
    }

    private func loadReconnectSnapshot() async -> RemoteReconnectSnapshot {
        await Task.detached(priority: .utility) {
            RemoteReconnectSnapshot(
                enabled: UserDefaults.standard.bool(forKey: "remoteAccessEnabled"),
                isConfigured: RemoteAccessKeychain.isConfigured,
                email: RemoteAccessKeychain.retrieveEmail(),
                subdomain: RemoteAccessKeychain.retrieveSubdomain(),
                tunnelToken: RemoteAccessKeychain.retrieveTunnelToken()
            )
        }.value
    }

    private func updateStatus(
        state: RemoteAccessState,
        url: String? = nil,
        subdomain: String? = nil,
        email: String? = nil,
        error: String? = nil
    ) async {
        await MainActor.run {
            RemoteAccessStatus.shared.update(
                state: state,
                url: url,
                subdomain: subdomain,
                email: email,
                error: error
            )
        }
    }

    private func resetStatus() async {
        await MainActor.run {
            RemoteAccessStatus.shared.reset()
        }
    }
}

// MARK: - CloudflaredManager extension for setting callback from @MainActor

extension CloudflaredManager {
    func setOnUnexpectedTermination(_ handler: @escaping @Sendable (Int32) -> Void) {
        self.onUnexpectedTermination = handler
    }
}
