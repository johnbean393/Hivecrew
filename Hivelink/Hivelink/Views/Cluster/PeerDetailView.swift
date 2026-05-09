//
//  PeerDetailView.swift
//  Hivelink
//

import HivecrewAPIModels
import HivecrewCore
import SwiftUI

struct PeerDetailView: View {
    let peer: DiscoveredClusterPeer

    private static let absoluteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()

    var body: some View {
        List {
            Section("Identity") {
                LabeledContent("Name") {
                    Text(peer.name ?? "—")
                }
                LabeledContent("Subdomain") {
                    Text(peer.subdomain)
                }
                LabeledContent("Tunnel URL") {
                    Text(peer.tunnelUrl)
                        .font(.caption)
                        .textSelection(.enabled)
                }
            }

            Section("Status") {
                HStack {
                    Text("Reachability")
                    Spacer()
                    StatusBadge(status: peer.status)
                }
                LabeledContent("Health probe") {
                    HealthIndicator(status: peer.status)
                }
            }

            Section("Capacity") {
                LabeledContent("Available slots") {
                    Text("\(peer.availableSlots)")
                }
                LabeledContent("Running tasks") {
                    Text("\(peer.runningTasks)")
                }
                LabeledContent("Queued tasks") {
                    Text("\(peer.queuedTasks)")
                }
            }

            Section("Providers") {
                if peer.providers.isEmpty {
                    Text("No provider capabilities reported")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(peer.providers.enumerated()), id: \.offset) { _, provider in
                        DisclosureGroup(provider.providerName) {
                            if provider.modelIds.isEmpty {
                                Text("No models listed")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(Array(provider.modelIds.enumerated()), id: \.offset) { _, modelId in
                                    Text(modelId)
                                        .font(.caption.monospaced())
                                }
                            }
                        }
                    }
                }
            }

            Section("Activity") {
                LabeledContent("Last seen") {
                    Text(Self.absoluteFormatter.string(from: peer.lastSeen))
                }
            }
        }
        .navigationTitle(peer.name ?? peer.subdomain)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct StatusBadge: View {
    let status: ClusterPeerReachabilityStatus

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.subheadline.weight(.medium))
        }
    }

    private var color: Color {
        switch status {
        case .online: return .green
        case .offline: return .red
        case .unreachable: return .gray
        case .dnsUnavailable: return .orange
        }
    }

    private var title: String {
        switch status {
        case .online: return "Online"
        case .offline: return "Offline"
        case .unreachable: return "Unreachable"
        case .dnsUnavailable: return "DNS unavailable"
        }
    }
}

private struct HealthIndicator: View {
    let status: ClusterPeerReachabilityStatus

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .foregroundStyle(color)
            Text(message)
                .font(.subheadline)
        }
    }

    private var iconName: String {
        switch status {
        case .online: return "checkmark.circle.fill"
        case .offline: return "xmark.circle.fill"
        case .unreachable: return "exclamationmark.triangle.fill"
        case .dnsUnavailable: return "network.slash"
        }
    }

    private var color: Color {
        switch status {
        case .online: return .green
        case .offline: return .red
        case .unreachable, .dnsUnavailable: return .orange
        }
    }

    private var message: String {
        switch status {
        case .online: return "Responding"
        case .offline: return "Not responding"
        case .unreachable: return "Intermittent"
        case .dnsUnavailable: return "DNS cannot resolve this tunnel"
        }
    }
}

#Preview {
    NavigationStack {
        PeerDetailView(
            peer: DiscoveredClusterPeer(
                id: "tunnel-1",
                subdomain: "worker.example.com",
                name: "Studio Mac",
                tunnelUrl: "https://worker.example.com",
                status: .online,
                availableSlots: 4,
                runningTasks: 2,
                queuedTasks: 0,
                lastSeen: Date(),
                providers: []
            )
        )
    }
}
