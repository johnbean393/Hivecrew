//
//  ClusterStatusView.swift
//  Hivelink
//

import HivecrewAPIModels
import HivecrewCore
import SwiftUI

struct ClusterStatusView: View {
    @EnvironmentObject private var coordinator: HivelinkClusterCoordinator

    private var onlinePeers: [DiscoveredClusterPeer] {
        coordinator.peers.filter { $0.status == .online }
    }

    private var totalAvailableSlots: Int {
        onlinePeers.reduce(0) { $0 + $1.availableSlots }
    }

    private var totalRunningTasks: Int {
        onlinePeers.reduce(0) { $0 + $1.runningTasks }
    }

    private var peerCount: Int {
        coordinator.peers.count
    }

    private var onlinePeerCount: Int {
        onlinePeers.count
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(totalAvailableSlots) available slots across \(peerCount) peers")
                        .font(.headline)
                    HStack {
                        Label("\(totalRunningTasks) active tasks", systemImage: "arrow.triangle.2.circlepath")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(onlinePeerCount) online")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Peers") {
                if coordinator.peers.isEmpty {
                    ContentUnavailableView(
                        "No peers yet",
                        systemImage: "server.rack",
                        description: Text("Pull to refresh or check your account’s Mac workers.")
                    )
                } else {
                    ForEach(coordinator.peers) { peer in
                        NavigationLink(value: peer) {
                            PeerRowView(peer: peer)
                        }
                    }
                }
            }
        }
        .navigationDestination(for: DiscoveredClusterPeer.self) { peer in
            PeerDetailView(peer: peer)
        }
        .refreshable {
            await coordinator.refreshPeers()
        }
    }
}

private struct PeerRowView: View {
    let peer: DiscoveredClusterPeer

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                StatusDot(status: peer.status)
                Text(peer.name ?? peer.subdomain)
                    .font(.headline)
                Spacer()
                Text(Self.relativeFormatter.localizedString(for: peer.lastSeen, relativeTo: Date()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("\(peer.availableSlots) available · \(peer.runningTasks) running")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if !peer.providers.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(Array(peer.providers.enumerated()), id: \.offset) { _, provider in
                        Text(provider.providerName)
                            .font(.caption2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct StatusDot: View {
    let status: ClusterPeerReachabilityStatus

    var body: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 10, height: 10)
            .accessibilityLabel(accessibilityLabel)
    }

    private var dotColor: Color {
        switch status {
        case .online: return .green
        case .offline: return .red
        case .unreachable: return .gray
        }
    }

    private var accessibilityLabel: String {
        switch status {
        case .online: return "Online"
        case .offline: return "Offline"
        case .unreachable: return "Unreachable"
        }
    }
}

/// Simple wrapping layout for provider pills.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.frames[index].minX, y: bounds.minY + result.frames[index].minY), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var frames: [CGRect] = []

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }

        let totalHeight = y + rowHeight
        let totalWidth = frames.map(\.maxX).max() ?? 0
        return (CGSize(width: totalWidth, height: totalHeight), frames)
    }
}

#Preview {
    NavigationStack {
        ClusterStatusView()
            .environmentObject(HivelinkClusterCoordinator())
    }
}
