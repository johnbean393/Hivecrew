//
//  SharedWidgetData.swift
//  Hivelink
//
//  Lightweight Codable DTOs shared between the main app and widget extension
//  via App Group UserDefaults. The widget extension cannot import HivecrewCore,
//  so these types are intentionally dependency-free.
//

import Foundation
import WidgetKit

// MARK: - Shared keys & accessor

enum SharedDefaults {
    static let suiteName = "group.com.pattonium.Hivelink"
    static let tasksKey = "widget.taskSummaries"
    static let clusterKey = "widget.clusterStatus"

    static var suite: UserDefaults {
        UserDefaults(suiteName: suiteName)!
    }
}

// MARK: - DTOs

struct SharedTaskSummary: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    let statusName: String
    let statusColor: String
    let peerName: String?
    let startedAt: Date?
    let isActive: Bool
}

struct SharedClusterStatus: Codable, Hashable {
    let peerCount: Int
    let onlinePeerCount: Int
    let totalAvailableSlots: Int
    let totalRunningTasks: Int
}

// MARK: - Reader (used by widgets)

enum SharedDataReader {
    static func taskSummaries() -> [SharedTaskSummary] {
        guard let data = SharedDefaults.suite.data(forKey: SharedDefaults.tasksKey) else {
            return []
        }
        return (try? JSONDecoder().decode([SharedTaskSummary].self, from: data)) ?? []
    }

    static func clusterStatus() -> SharedClusterStatus {
        guard let data = SharedDefaults.suite.data(forKey: SharedDefaults.clusterKey),
              let status = try? JSONDecoder().decode(SharedClusterStatus.self, from: data)
        else {
            return SharedClusterStatus(peerCount: 0, onlinePeerCount: 0, totalAvailableSlots: 0, totalRunningTasks: 0)
        }
        return status
    }
}

// MARK: - Writer (used by main app after reconciliation)

enum SharedDataWriter {
    static func writeTaskSummaries(_ summaries: [SharedTaskSummary]) {
        if let data = try? JSONEncoder().encode(summaries) {
            SharedDefaults.suite.set(data, forKey: SharedDefaults.tasksKey)
        }
    }

    static func writeClusterStatus(_ status: SharedClusterStatus) {
        if let data = try? JSONEncoder().encode(status) {
            SharedDefaults.suite.set(data, forKey: SharedDefaults.clusterKey)
        }
    }

    static func reloadWidgets() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}
