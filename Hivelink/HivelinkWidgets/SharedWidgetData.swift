//
//  SharedWidgetData.swift
//  HivelinkWidgets
//
//  Duplicated Codable DTOs for the widget extension target.
//  Must stay in sync with Hivelink/Models/SharedWidgetData.swift.
//

import Foundation

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

// MARK: - Reader

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
