//
//  HivelinkWidgetsBundle.swift
//  HivelinkWidgets
//

import SwiftUI
import WidgetKit

@main
struct HivelinkWidgetsBundle: WidgetBundle {
    var body: some Widget {
        ActiveTasksWidget()
        ClusterStatusWidget()
        ActiveTaskCountAccessoryWidget()
        TaskLiveActivity()
    }
}
