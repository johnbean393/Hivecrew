//
//  ActiveTaskCountAccessoryWidget.swift
//  HivelinkWidgets
//
//  Lock Screen accessory widget showing active task count.
//

import SwiftUI
import WidgetKit

// MARK: - Timeline

struct ActiveTaskCountEntry: TimelineEntry {
    let date: Date
    let activeCount: Int
}

struct ActiveTaskCountProvider: TimelineProvider {
    func placeholder(in context: Context) -> ActiveTaskCountEntry {
        ActiveTaskCountEntry(date: .now, activeCount: 2)
    }

    func getSnapshot(in context: Context, completion: @escaping (ActiveTaskCountEntry) -> Void) {
        let count = SharedDataReader.taskSummaries().filter(\.isActive).count
        completion(ActiveTaskCountEntry(date: .now, activeCount: count))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ActiveTaskCountEntry>) -> Void) {
        let count = SharedDataReader.taskSummaries().filter(\.isActive).count
        let entry = ActiveTaskCountEntry(date: .now, activeCount: count)
        let nextUpdate = Date().addingTimeInterval(60)
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }
}

// MARK: - Widget

struct ActiveTaskCountAccessoryWidget: Widget {
    let kind = "ActiveTaskCountAccessory"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ActiveTaskCountProvider()) { entry in
            ActiveTaskCountAccessoryView(entry: entry)
        }
        .configurationDisplayName("Task Count")
        .description("Active task count on your Lock Screen.")
        .supportedFamilies([.accessoryCircular, .accessoryInline])
    }
}

// MARK: - Views

struct ActiveTaskCountAccessoryView: View {
    var entry: ActiveTaskCountEntry

    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            circularView
        case .accessoryInline:
            inlineView
        default:
            circularView
        }
    }

    private var circularView: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 1) {
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.caption)
                Text("\(entry.activeCount)")
                    .font(.system(.title2, design: .rounded, weight: .bold))
            }
        }
    }

    private var inlineView: some View {
        Label {
            Text("\(entry.activeCount) active task\(entry.activeCount == 1 ? "" : "s")")
        } icon: {
            Image(systemName: "circle.hexagongrid.fill")
        }
    }
}
