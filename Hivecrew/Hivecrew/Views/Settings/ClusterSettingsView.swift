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
                    peerRow(selfPeer, isOnline: true)
                }

                ForEach(orderedPeerIds, id: \.self) { tunnelId in
                    if let peer = peerInfos.first(where: { $0.tunnelId == tunnelId }) {
                        peerRow(peer, isOnline: isPeerOnline(peer))
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
    private func peerRow(_ peer: ClusterPeerInfo, isOnline: Bool) -> some View {
        HStack {
            Circle()
                .fill(peerDotColor(isOnline: isOnline))
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
                    if !isOnline {
                        Text("Offline")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15))
                            .foregroundColor(.secondary)
                            .clipShape(Capsule())
                    }
                }
                Text(peer.subdomain + ".hivecrew.org")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .opacity(isOnline ? 1.0 : 0.5)
            
            Spacer()
        }
        .padding(.vertical, 2)
    }
    
    private func peerDotColor(isOnline: Bool) -> Color {
        guard isOnline else { return .gray }
        return .green
    }
    
    private func isPeerOnline(_ peer: ClusterPeerInfo) -> Bool {
        if peer.tunnelId == RemoteAccessKeychain.retrieveTunnelId() {
            return true
        }
        
        return clusterStatus.peers.contains { $0.id == peer.tunnelId && $0.status == .online }
    }
    
    // MARK: - Actions
    
    private func loadClusterInfo() {
        guard isRemoteAccessConnected else { return }
        guard let sessionToken = RemoteAccessKeychain.retrieveSessionToken() else { return }
        
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                let apiClient = RemoteAccessAPIClient()
                let info = try await apiClient.getClusterInfo(sessionToken: sessionToken)
                let myId = RemoteAccessKeychain.retrieveTunnelId()
                
                await MainActor.run {
                    peerInfos = info.peers
                    
                    let savedOrder = ClusterManager.shared.getDispatchOrder()
                    let peerIds = info.peers
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
                    
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
}
