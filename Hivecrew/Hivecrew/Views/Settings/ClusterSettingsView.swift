//
//  ClusterSettingsView.swift
//  Hivecrew
//
//  Settings tab for cluster configuration and peer visibility
//

import SwiftUI
import HivecrewAPI
import HivecrewCore

struct ClusterSettingsView: View {
    @ObservedObject private var remoteStatus = RemoteAccessStatus.shared
    @ObservedObject private var clusterStatus = ClusterStatus.shared
    
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var peerInfos: [ClusterPeerInfo] = []
    @State private var orderedPeerIds: [String] = []
    @State private var peerPendingRemoval: ClusterPeerInfo?
    @State private var peerRemovalInProgress: String?
    @State private var showingRemovePeerConfirmation = false
    
    private var isRemoteAccessConnected: Bool {
        remoteStatus.state == .connected
    }
    
    var body: some View {
        Form {
            if !isRemoteAccessConnected {
                remoteAccessRequiredSection
            } else {
                peerListSection
            }
        }
        .formStyle(.grouped)
        .onAppear { loadClusterInfo() }
        .onChange(of: remoteStatus.state) { _, newState in
            if newState == .connected {
                loadClusterInfo()
            }
        }
        .onChange(of: clusterStatus.role) { _, _ in
            if isRemoteAccessConnected {
                loadClusterInfo()
            }
        }
        .alert("Remove Machine?", isPresented: $showingRemovePeerConfirmation, presenting: peerPendingRemoval) { peer in
            Button("Remove", role: .destructive) {
                removePeer(peer)
            }
            Button("Cancel", role: .cancel) {
                peerPendingRemoval = nil
            }
        } message: { peer in
            Text("This removes \(peer.name ?? peer.subdomain) from the cluster directory. If that Mac still needs remote access, reconnect remote access on that Mac.")
        }
    }
    
    // MARK: - Sections
    
    private var remoteAccessRequiredSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Remote Access Required", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.headline)
                Text("Set up remote access in the Connect tab before joining the cluster mesh. All machines in the cluster must be signed in with the same email.")
                    .foregroundColor(.secondary)
                
                Button("Go to Connect Settings") {
                    NotificationCenter.default.post(
                        name: .navigateToSettingsTab,
                        object: SettingsView.SettingsTab.api
                    )
                }
                .padding(.top, 4)
            }
            .padding(.vertical, 4)
        }
    }
    
    private var peerListSection: some View {
        Section {
            if let errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            if peerInfos.isEmpty {
                Text("No peers found. Other machines will appear here once they connect with the same email.")
                    .foregroundColor(.secondary)
                    .font(.callout)
            } else {
                if let myId = RemoteAccessKeychain.retrieveTunnelId(),
                   let selfPeer = peerInfos.first(where: { $0.tunnelId == myId }) {
                    peerRow(selfPeer, status: .online)
                }

                ForEach(orderedPeerIds, id: \.self) { tunnelId in
                    if let peer = peerInfos.first(where: { $0.tunnelId == tunnelId }) {
                        let status = peerStatus(peer)
                        peerRow(peer, status: status, canRemove: canRemovePeer(peer, status: status))
                            .draggable(tunnelId) {
                                Text(peer.name ?? peer.subdomain)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.ultraThinMaterial)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .dropDestination(for: String.self) { droppedIds, _ in
                                guard let fromId = droppedIds.first,
                                      let fromIndex = orderedPeerIds.firstIndex(of: fromId),
                                      let toIndex = orderedPeerIds.firstIndex(of: tunnelId),
                                      fromIndex != toIndex else {
                                    return false
                                }
                                withAnimation {
                                    orderedPeerIds.move(
                                        fromOffsets: IndexSet(integer: fromIndex),
                                        toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex
                                    )
                                }
                                ClusterManager.shared.setDispatchOrder(orderedPeerIds)
                                return true
                            }
                    }
                }
            }
            
            Button("Refresh") { loadClusterInfo() }
                .disabled(isLoading)
        } header: {
            Text("Machines")
        } footer: {
            if !orderedPeerIds.isEmpty {
                Text("Drag machines to set dispatch priority.")
            } else {
                Text("All machines signed in with the same email participate in the cluster automatically when remote access is connected.")
            }
        }
    }
    
    // MARK: - Peer Row
    
    @ViewBuilder
    private func peerRow(_ peer: ClusterPeerInfo, status: PeerStatus, canRemove: Bool = false) -> some View {
        HStack {
            Circle()
                .fill(peerDotColor(status: status))
                .frame(width: 8, height: 8)
            
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(peer.name ?? peer.subdomain)
                        .fontWeight(.medium)
                    if peer.tunnelId == RemoteAccessKeychain.retrieveTunnelId() {
                        Text("This Device")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.blue.opacity(0.15))
                            .foregroundColor(.blue)
                            .clipShape(Capsule())
                    }
                    if status != .online {
                        Text(peerStatusLabel(status))
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(peerStatusColor(status).opacity(0.15))
                            .foregroundColor(peerStatusColor(status))
                            .clipShape(Capsule())
                    }
                }
                Text(peer.subdomain + ".hivecrew.org")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .opacity(status == .online ? 1.0 : 0.5)
            
            Spacer()

            if canRemove {
                Button {
                    peerPendingRemoval = peer
                    showingRemovePeerConfirmation = true
                } label: {
                    Image(systemName: peerRemovalInProgress == peer.tunnelId ? "hourglass" : "trash")
                }
                .buttonStyle(.borderless)
                .foregroundColor(.red)
                .disabled(peerRemovalInProgress != nil || isLoading)
                .help(removePeerHelpText(status))
            }
        }
        .padding(.vertical, 2)
    }
    
    private func peerDotColor(status: PeerStatus) -> Color {
        switch status {
        case .online:
            return .green
        case .unreachable, .dnsUnavailable:
            return .yellow
        case .offline:
            return .gray
        }
    }
    
    private func peerStatus(_ peer: ClusterPeerInfo) -> PeerStatus {
        if peer.tunnelId == RemoteAccessKeychain.retrieveTunnelId() {
            return .online
        }
        
        return clusterStatus.peers.first { $0.id == peer.tunnelId }?.status ?? .offline
    }

    private func peerStatusLabel(_ status: PeerStatus) -> String {
        switch status {
        case .online:
            return "Online"
        case .dnsUnavailable:
            return "DNS unavailable"
        case .unreachable:
            return "Unreachable"
        case .offline:
            return "Offline"
        }
    }

    private func peerStatusColor(_ status: PeerStatus) -> Color {
        switch status {
        case .online:
            return .green
        case .dnsUnavailable, .unreachable:
            return .yellow
        case .offline:
            return .secondary
        }
    }

    private func canRemovePeer(_ peer: ClusterPeerInfo, status: PeerStatus) -> Bool {
        peer.tunnelId != RemoteAccessKeychain.retrieveTunnelId() && status != .online
    }

    private func removePeerHelpText(_ status: PeerStatus) -> String {
        status == .dnsUnavailable
            ? "Remove machine from cluster directory. This Mac's DNS cannot currently resolve it."
            : "Remove stale machine"
    }
    
    // MARK: - Actions
    
    private func loadClusterInfo() {
        guard isRemoteAccessConnected else { return }
        guard let sessionToken = RemoteAccessKeychain.retrieveSessionToken() else {
            applyPeerDirectory(ClusterPeerDirectoryCache.retrieve())
            errorMessage = expiredSessionMessage
            return
        }
        
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                let apiClient = RemoteAccessAPIClient()
                let info = try await apiClient.getClusterInfo(sessionToken: sessionToken)
                ClusterPeerDirectoryCache.store(info.peers)
                if let clusterToken = info.clusterToken {
                    await ClusterManager.shared.refreshPeersFromDirectory(info.peers, clusterToken: clusterToken)
                }
                
                await MainActor.run {
                    applyPeerDirectory(info.peers)
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    let cachedPeers = ClusterPeerDirectoryCache.retrieve()
                    if !cachedPeers.isEmpty {
                        applyPeerDirectory(cachedPeers)
                    }
                    errorMessage = clusterDirectoryErrorMessage(error)
                    isLoading = false
                }
            }
        }
    }

    private func removePeer(_ peer: ClusterPeerInfo) {
        guard peer.tunnelId != RemoteAccessKeychain.retrieveTunnelId() else { return }
        guard let sessionToken = RemoteAccessKeychain.retrieveSessionToken() else {
            errorMessage = expiredSessionMessage
            return
        }

        peerRemovalInProgress = peer.tunnelId
        errorMessage = nil

        Task {
            do {
                let apiClient = RemoteAccessAPIClient()
                try await apiClient.deleteTunnel(tunnelId: peer.tunnelId, sessionToken: sessionToken)
                await removePeerLocally(peer.tunnelId)
            } catch {
                if isMissingTunnelError(error) {
                    await removePeerLocally(peer.tunnelId)
                } else {
                    await MainActor.run {
                        errorMessage = error.localizedDescription
                        peerRemovalInProgress = nil
                    }
                }
            }
        }
    }

    @MainActor
    private func removePeerLocally(_ tunnelId: String) async {
        await ClusterManager.shared.removePeer(tunnelId: tunnelId)
        let updatedPeers = peerInfos.filter { $0.tunnelId != tunnelId }
        let updatedOrder = orderedPeerIds.filter { $0 != tunnelId }
        ClusterPeerDirectoryCache.store(updatedPeers)
        ClusterManager.shared.setDispatchOrder(updatedOrder)
        applyPeerDirectory(updatedPeers)
        peerPendingRemoval = nil
        peerRemovalInProgress = nil
    }

    private func isMissingTunnelError(_ error: Error) -> Bool {
        switch error {
        case RemoteAccessError.httpError(let statusCode) where statusCode == 404:
            return true
        case RemoteAccessError.serverError(let statusCode, _) where statusCode == 404:
            return true
        default:
            return false
        }
    }

    private var expiredSessionMessage: String {
        "Remote access needs you to sign in again before this machine can refresh the cluster directory."
    }

    private func clusterDirectoryErrorMessage(_ error: Error) -> String {
        switch error {
        case RemoteAccessError.httpError(let statusCode) where statusCode == 401:
            return expiredSessionMessage
        case RemoteAccessError.serverError(let statusCode, _) where statusCode == 401:
            return expiredSessionMessage
        default:
            let message = error.localizedDescription
            if message.localizedCaseInsensitiveContains("invalid or expired token") {
                return expiredSessionMessage
            }
            return message
        }
    }

    private func applyPeerDirectory(_ peers: [ClusterPeerInfo]) {
        let myId = RemoteAccessKeychain.retrieveTunnelId()
        peerInfos = peers

        let savedOrder = ClusterManager.shared.getDispatchOrder()
        let peerIds = peers
            .filter { $0.tunnelId != myId }
            .map(\.tunnelId)

        var ordered: [String] = []
        for id in savedOrder where peerIds.contains(id) {
            ordered.append(id)
        }
        for id in peerIds where !ordered.contains(id) {
            ordered.append(id)
        }
        orderedPeerIds = ordered
    }
}
