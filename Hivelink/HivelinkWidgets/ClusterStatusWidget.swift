//
//  ClusterStatusWidget.swift
//  HivelinkWidgets
//
//  Small Home Screen widget showing cluster peer count, capacity, and health.
//

import SwiftUI
import WidgetKit

// MARK: - Timeline

struct ClusterStatusEntry: TimelineEntry {
    let date: Date
    let cluster: SharedClusterStatus
}

struct ClusterStatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> ClusterStatusEntry {
        ClusterStatusEntry(date: .now, cluster: SharedClusterStatus(peerCount: 2, onlinePeerCount: 2, totalAvailableSlots: 4, totalRunningTasks: 1))
    }

    func getSnapshot(in context: Context, completion: @escaping (ClusterStatusEntry) -> Void) {
        completion(ClusterStatusEntry(date: .now, cluster: SharedDataReader.clusterStatus()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ClusterStatusEntry>) -> Void) {
        let entry = ClusterStatusEntry(date: .now, cluster: SharedDataReader.clusterStatus())
        let nextUpdate = Date().addingTimeInterval(60)
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }
}

// MARK: - Widget

struct ClusterStatusWidget: Widget {
    let kind = "ClusterStatusWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ClusterStatusProvider()) { entry in
            ClusterStatusWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Cluster Status")
        .description("Peer count, capacity, and health at a glance.")
        .supportedFamilies([.systemSmall])
    }
}

// MARK: - View

struct ClusterStatusWidgetView: View {
    var entry: ClusterStatusEntry

    private var cluster: SharedClusterStatus { entry.cluster }

    private var healthColor: Color {
        if cluster.peerCount == 0 { return .gray }
        if cluster.onlinePeerCount == cluster.peerCount { return .green }
        if cluster.onlinePeerCount > 0 { return .yellow }
        return .red
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(healthColor)
                    .frame(width: 10, height: 10)
                Text("Cluster")
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 6) {
                statRow(icon: "desktopcomputer", value: "\(cluster.onlinePeerCount)", label: "Peers online")
                statRow(icon: "cpu", value: "\(cluster.totalAvailableSlots)", label: "Available slots")
                statRow(icon: "bolt.fill", value: "\(cluster.totalRunningTasks)", label: "Running")
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statRow(icon: String, value: String, label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}
