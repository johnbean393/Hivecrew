//
//  ClusterSettingsView.swift
//  Hivecrew
//
//  Settings tab for cluster configuration (coordinator toggle, peer list)
//

import SwiftUI
import HivecrewAPI

struct ClusterSettingsView: View {
    @ObservedObject private var remoteStatus = RemoteAccessStatus.shared
    @ObservedObject private var clusterStatus = ClusterStatus.shared
    
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var peerInfos: [ClusterPeerInfo] = []
    @State private var workerPeerIds: [String] = []
    @State private var livePeerStatuses: [String: PeerStatus] = [:]
    @State private var showRemoveConfirmation = false
    /// True when another machine in the cluster is already the coordinator
    @State private var anotherMachineIsCoordinator = false
    
    private var isRemoteAccessConnected: Bool {
        remoteStatus.state == .connected
    }
    
    var body: some View {
        Form {
            if !isRemoteAccessConnected {
                remoteAccessRequiredSection
            } else {
                coordinatorSection
                
                if clusterStatus.role != .none {
                    peerListSection
                }
                
                if clusterStatus.role == .worker {
                    workerInfoSection
                }
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
                Text("Set up remote access in the Connect tab before configuring cluster mode. All machines in the cluster must be signed in with the same email.")
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
    
    private var coordinatorSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { clusterStatus.role == .coordinator },
                set: { newValue in
                    if newValue {
                        designateAsCoordinator()
                    } else {
                        showRemoveConfirmation = true
                    }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Act as Coordinator")
                    if anotherMachineIsCoordinator {
                        Text("Another machine in the cluster is already the coordinator.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("This machine will dispatch overflow tasks to other machines in the cluster.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .disabled(isLoading || anotherMachineIsCoordinator)
            .alert("Remove Coordinator Role?", isPresented: $showRemoveConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Remove", role: .destructive) { removeCoordinator() }
            } message: {
                Text("This will dissolve the cluster. All machines will return to standalone mode.")
            }
            
            if let errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
            }
        } header: {
            Text("Cluster Role")
        } footer: {
            if clusterStatus.role == .none && !anotherMachineIsCoordinator {
                Text("Enable coordinator mode to allow this machine to distribute tasks to other Hivecrew instances signed in with the same email.")
            }
        }
    }
    
    private var peerListSection: some View {
        Section {
            if peerInfos.isEmpty {
                Text("No peers found. Other machines will appear here once they connect with the same email.")
                    .foregroundColor(.secondary)
                    .font(.callout)
            } else if clusterStatus.role == .coordinator {
                // Coordinator's own row (always online, not draggable)
                if let myId = RemoteAccessKeychain.retrieveTunnelId(),
                   let coordPeer = peerInfos.first(where: { $0.tunnelId == myId }) {
                    peerRow(coordPeer, isOnline: true)
                }
                
                // Worker rows (with live status, draggable for dispatch order)
                ForEach(workerPeerIds, id: \.self) { tunnelId in
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
                                      let fromIndex = workerPeerIds.firstIndex(of: fromId),
                                      let toIndex = workerPeerIds.firstIndex(of: tunnelId),
                                      fromIndex != toIndex else {
                                    return false
                                }
                                withAnimation {
                                    workerPeerIds.move(
                                        fromOffsets: IndexSet(integer: fromIndex),
                                        toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex
                                    )
                                }
                                ClusterManager.shared.setDispatchOrder(workerPeerIds)
                                return true
                            }
                    }
                }
            } else {
                ForEach(peerInfos, id: \.tunnelId) { peer in
                    peerRow(peer, isOnline: isPeerOnline(peer))
                }
            }
            
            Button("Refresh") { loadClusterInfo() }
                .disabled(isLoading)
        } header: {
            Text("Machines")
        } footer: {
            if clusterStatus.role == .coordinator && !workerPeerIds.isEmpty {
                Text("Drag workers to set task dispatch priority.")
            } else {
                Text("All machines signed in with the same email. Workers automatically register with the coordinator when they come online.")
            }
        }
    }
    
    private var workerInfoSection: some View {
        Section {
            if let url = clusterStatus.coordinatorUrl {
                LabeledContent("Coordinator") {
                    Text(url)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }
            
            Text("This machine is part of a cluster. The coordinator may dispatch tasks here when its own capacity is full.")
                .foregroundColor(.secondary)
                .font(.callout)
        } header: {
            Text("Worker Status")
        }
    }
    
    // MARK: - Peer Row
    
    @ViewBuilder
    private func peerRow(_ peer: ClusterPeerInfo, isOnline: Bool) -> some View {
        HStack {
            Circle()
                .fill(peerDotColor(role: peer.role, isOnline: isOnline))
                .frame(width: 8, height: 8)
            
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(peer.name ?? peer.subdomain)
                        .fontWeight(.medium)
                    if peer.role == "coordinator" {
                        Text("Coordinator")
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
    
    private func peerDotColor(role: String, isOnline: Bool) -> Color {
        guard isOnline else { return .gray }
        return role == "coordinator" ? .blue : .green
    }
    
    private func isPeerOnline(_ peer: ClusterPeerInfo) -> Bool {
        if clusterStatus.role == .coordinator {
            return clusterStatus.peers.contains { $0.id == peer.tunnelId && $0.status == .online }
        }
        
        if peer.tunnelId == RemoteAccessKeychain.retrieveTunnelId() {
            return true
        }
        
        return livePeerStatuses[peer.tunnelId] == .online
    }
    
    private func workerPeerStatuses(
        info: ClusterInfoResponse,
        myId: String?
    ) async -> [String: PeerStatus] {
        var statuses: [String: PeerStatus] = [:]
        if let myId {
            statuses[myId] = .online
        }
        
        let isWorker = info.hasCluster && info.coordinatorTunnelId != myId
        guard isWorker,
              let coordinatorUrl = clusterStatus.coordinatorUrl ?? info.coordinatorUrl,
              let clusterToken = RemoteAccessKeychain.retrieveClusterToken() else {
            return statuses
        }
        
        let client = PeerAPIClient(baseURL: coordinatorUrl, clusterToken: clusterToken)
        do {
            let status = try await client.getClusterStatus()
            if let coordinatorId = info.coordinatorTunnelId {
                statuses[coordinatorId] = .online
            }
            for peer in status.peers {
                statuses[peer.tunnelId] = switch peer.status {
                case "online": .online
                case "unreachable": .unreachable
                default: .offline
                }
            }
        } catch {
            print("ClusterSettingsView: Failed to fetch live peer statuses from coordinator: \(error)")
        }
        
        return statuses
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
                let workerStatuses = await workerPeerStatuses(info: info, myId: myId)
                
                await MainActor.run {
                    peerInfos = info.peers
                    livePeerStatuses = workerStatuses
                    
                    // Detect if another machine is already the coordinator
                    if info.hasCluster,
                       let coordId = info.coordinatorTunnelId,
                       coordId != myId {
                        anotherMachineIsCoordinator = true
                    } else {
                        anotherMachineIsCoordinator = false
                    }
                    
                    if clusterStatus.role == .coordinator {
                        let savedOrder = ClusterManager.shared.getDispatchOrder()
                        let workerIds = info.peers
                            .filter { $0.tunnelId != myId }
                            .map(\.tunnelId)
                        
                        var ordered: [String] = []
                        for id in savedOrder where workerIds.contains(id) {
                            ordered.append(id)
                        }
                        for id in workerIds where !ordered.contains(id) {
                            ordered.append(id)
                        }
                        workerPeerIds = ordered
                    }
                    
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
    
    private func designateAsCoordinator() {
        guard let sessionToken = RemoteAccessKeychain.retrieveSessionToken(),
              let tunnelId = RemoteAccessKeychain.retrieveTunnelId() else {
            errorMessage = "Missing credentials"
            return
        }
        
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                let apiClient = RemoteAccessAPIClient()
                let response = try await apiClient.designateCoordinator(tunnelId: tunnelId, sessionToken: sessionToken)
                
                RemoteAccessKeychain.storeClusterToken(response.clusterToken)
                UserDefaults.standard.set(true, forKey: "clusterCoordinatorEnabled")
                
                await ClusterManager.shared.configure(
                    role: .coordinator,
                    clusterToken: response.clusterToken,
                    coordinatorUrl: response.coordinatorUrl
                )
                
                await MainActor.run {
                    isLoading = false
                    loadClusterInfo()
                }
                
                // Restart API server to pick up coordinator mode
                APIServerManager.shared.restart()
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
    
    private func removeCoordinator() {
        guard let sessionToken = RemoteAccessKeychain.retrieveSessionToken() else {
            errorMessage = "Missing credentials"
            return
        }
        
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                let apiClient = RemoteAccessAPIClient()
                try await apiClient.removeCluster(sessionToken: sessionToken)
                
                RemoteAccessKeychain.deleteClusterToken()
                RemoteAccessKeychain.deleteCoordinatorUrl()
                UserDefaults.standard.set(false, forKey: "clusterCoordinatorEnabled")
                
                await ClusterManager.shared.configure(role: .none, clusterToken: nil, coordinatorUrl: nil)
                
                await MainActor.run {
                    peerInfos = []
                    workerPeerIds = []
                    isLoading = false
                }
                
                APIServerManager.shared.restart()
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
}
