//
//  PeerNode.swift
//  Hivecrew
//
//  Model representing a peer machine in the cluster
//

import Foundation
import HivecrewAPI

enum PeerCapabilityMatch: Equatable {
    case supported
    case unsupported
    case unknown
}

/// A peer machine in the cluster known to the local mesh member
struct PeerNode: Identifiable, Codable, Sendable {
    /// Tunnel ID (unique identifier from the Cloudflare Worker)
    let id: String
    /// Server-generated subdomain (e.g. "xk92m")
    let subdomain: String
    /// Machine hostname at registration time
    let name: String?
    /// Full tunnel URL (e.g. "https://xk92m.hivecrew.org")
    var tunnelUrl: String
    /// Whether this peer is currently reachable
    var status: PeerStatus
    /// Number of VM slots currently free on this peer
    var availableSlots: Int
    /// Number of tasks currently running on this peer
    var runningTasks: Int
    /// Number of tasks currently queued on this peer
    var queuedTasks: Int
    /// Last time we heard from this peer
    var lastSeen: Date
    /// Provider/model capabilities advertised by this peer
    var providers: [PeerProviderSummary]
    
    /// Returns the capability state for dispatch decisions.
    /// Unknown capability information should not be treated as a positive match.
    nonisolated func capabilityMatch(providerName: String, modelId: String) -> PeerCapabilityMatch {
        guard !providers.isEmpty else { return .unknown }

        let lowercasedProviderName = providerName.lowercased()
        guard let provider = providers.first(where: { $0.providerName.lowercased() == lowercasedProviderName }) else {
            return .unsupported
        }
        guard !provider.modelIds.isEmpty else {
            return .unknown
        }
        return provider.modelIds.contains(modelId) ? .supported : .unsupported
    }

    nonisolated var hasUnknownCapabilities: Bool {
        providers.isEmpty || providers.contains(where: { $0.modelIds.isEmpty })
    }
}

enum PeerStatus: String, Codable, Sendable {
    case online
    case offline
    case unreachable
}
