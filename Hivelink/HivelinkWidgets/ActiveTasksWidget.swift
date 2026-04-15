//
//  ActiveTasksWidget.swift
//  HivelinkWidgets
//
//  Home Screen widget showing active task summaries (small / medium / large).
//

import SwiftUI
import WidgetKit

// MARK: - Timeline

struct ActiveTasksEntry: TimelineEntry {
    let date: Date
    let tasks: [SharedTaskSummary]
}

struct ActiveTasksProvider: TimelineProvider {
    func placeholder(in context: Context) -> ActiveTasksEntry {
        ActiveTasksEntry(date: .now, tasks: [
            SharedTaskSummary(id: "1", title: "Example task", statusName: "In Progress", statusColor: "green", peerName: "Mac Studio", startedAt: .now, isActive: true)
        ])
    }

    func getSnapshot(in context: Context, completion: @escaping (ActiveTasksEntry) -> Void) {
        let tasks = SharedDataReader.taskSummaries()
        completion(ActiveTasksEntry(date: .now, tasks: tasks))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ActiveTasksEntry>) -> Void) {
        let tasks = SharedDataReader.taskSummaries()
        let entry = ActiveTasksEntry(date: .now, tasks: tasks)
        let nextUpdate = Date().addingTimeInterval(60)
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }
}

// MARK: - Widget

struct ActiveTasksWidget: Widget {
    let kind = "ActiveTasksWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ActiveTasksProvider()) { entry in
            ActiveTasksWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Active Tasks")
        .description("Shows your running Hivelink tasks.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Views

struct ActiveTasksWidgetView: View {
    var entry: ActiveTasksEntry

    @Environment(\.widgetFamily) var family

    private var activeTasks: [SharedTaskSummary] {
        entry.tasks.filter(\.isActive)
    }

    var body: some View {
        switch family {
        case .systemSmall:
            smallView
        case .systemMedium:
            mediumView
        case .systemLarge:
            largeView
        default:
            smallView
        }
    }

    // MARK: Small

    private var smallView: some View {
        VStack(spacing: 6) {
            Image(systemName: "circle.hexagongrid.fill")
                .font(.title)
                .foregroundStyle(.orange)

            Text("\(activeTasks.count)")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .contentTransition(.numericText())

            Text(activeTasks.count == 1 ? "Active Task" : "Active Tasks")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Medium

    private var mediumView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("\(activeTasks.count) Active", systemImage: "circle.hexagongrid.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Spacer()
            }

            if activeTasks.isEmpty {
                Text("No active tasks")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ForEach(activeTasks.prefix(3)) { task in
                    taskRow(task)
                }
            }
        }
        .padding(2)
    }

    // MARK: Large

    private var largeView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("\(activeTasks.count) Active", systemImage: "circle.hexagongrid.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Spacer()
            }

            if activeTasks.isEmpty {
                Spacer()
                Text("No active tasks")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ForEach(activeTasks.prefix(8)) { task in
                    taskRow(task)
                    if task.id != activeTasks.prefix(8).last?.id {
                        Divider()
                    }
                }
                if activeTasks.count > 8 {
                    Text("+\(activeTasks.count - 8) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(2)
    }

    // MARK: Row

    private func taskRow(_ task: SharedTaskSummary) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color(for: task.statusColor))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(task.title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(task.statusName)
                        .font(.caption2)
                        .foregroundStyle(color(for: task.statusColor))

                    if let peer = task.peerName {
                        Text("· \(peer)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 0)

            if let started = task.startedAt {
                Text(elapsed(since: started))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Helpers

    private func color(for name: String) -> Color {
        switch name {
        case "green": return .green
        case "yellow": return .yellow
        case "red": return .red
        case "orange": return .orange
        case "blue": return .blue
        case "gray": return .gray
        default: return .secondary
        }
    }

    private func elapsed(since date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}
