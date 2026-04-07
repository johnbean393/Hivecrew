//
//  PeerNode.swift
//  Hivecrew
//
//  Model representing a peer machine in the cluster
//

import Foundation
import HivecrewAPI

/// A peer machine in the cluster known to the coordinator
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
    
    /// Returns true if this peer can plausibly handle the given provider+model.
    /// When modelIds is empty (capabilities not yet enumerated), matches by provider name alone.
    func hasProvider(name: String, modelId: String) -> Bool {
        providers.contains { prov in
            prov.providerName == name && (prov.modelIds.isEmpty || prov.modelIds.contains(modelId))
        }
    }
}

enum PeerStatus: String, Codable, Sendable {
    case online
    case offline
    case unreachable
}
