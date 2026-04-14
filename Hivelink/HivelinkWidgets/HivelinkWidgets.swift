//
//  HivelinkWidgets.swift
//  HivelinkWidgets
//

import SwiftUI
import WidgetKit

struct HivelinkWidgetsEntry: TimelineEntry {
    let date: Date
}

struct HivelinkWidgetsProvider: TimelineProvider {
    func placeholder(in context: Context) -> HivelinkWidgetsEntry {
        HivelinkWidgetsEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (HivelinkWidgetsEntry) -> Void) {
        completion(HivelinkWidgetsEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HivelinkWidgetsEntry>) -> Void) {
        let entry = HivelinkWidgetsEntry(date: Date())
        completion(Timeline(entries: [entry], policy: .never))
    }
}

struct HivelinkWidgetsEntryView: View {
    var entry: HivelinkWidgetsProvider.Entry

    var body: some View {
        Text("Hivelink")
    }
}

struct HivelinkWidgets: Widget {
    let kind: String = "HivelinkWidgets"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HivelinkWidgetsProvider()) { entry in
            HivelinkWidgetsEntryView(entry: entry)
        }
        .configurationDisplayName("Hivelink")
        .description("Placeholder widget.")
    }
}
