//
//  ClusterPeerDirectoryCache.swift
//  HivecrewCore
//
//  Persists the most recent Worker peer directory so cluster members can keep
//  discovering known peers when the account session token needs re-auth.
//

import Foundation

public enum ClusterPeerDirectoryCache {
    private static let peersKey = "clusterPeerDirectoryCache.peers"
    private static let savedAtKey = "clusterPeerDirectoryCache.savedAt"

    public static func store(_ peers: [ClusterPeerInfo]) {
        guard let data = try? JSONEncoder().encode(peers) else { return }
        UserDefaults.standard.set(data, forKey: peersKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: savedAtKey)
    }

    public static func retrieve() -> [ClusterPeerInfo] {
        guard let data = UserDefaults.standard.data(forKey: peersKey),
              let peers = try? JSONDecoder().decode([ClusterPeerInfo].self, from: data) else {
            return []
        }
        return peers
    }

    public static func clear() {
        UserDefaults.standard.removeObject(forKey: peersKey)
        UserDefaults.standard.removeObject(forKey: savedAtKey)
    }
}
