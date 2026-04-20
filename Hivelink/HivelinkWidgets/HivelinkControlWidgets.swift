//
//  HivelinkControlWidgets.swift
//  HivelinkWidgets
//
//  Control Center / Lock Screen / Action Button widgets for quick
//  access to Hivelink's core actions.
//

import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Control Widget Intents

struct ControlStartCallIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Hivelink Call"
    static let description = IntentDescription("Opens Hivelink and starts a voice session.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        return .result()
    }
}

struct ControlNewTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "New Hivelink Task"
    static let description = IntentDescription("Opens Hivelink and focuses the task prompt.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        return .result()
    }
}

struct ControlSetIncomingCallsIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Pause Incoming Calls"
    static let description = IntentDescription("Toggles whether Hivelink accepts incoming calls.")

    @Parameter(title: "Allowed")
    var value: Bool

    func perform() async throws -> some IntentResult {
        FocusFilterPreferences.setAllowIncomingCalls(value)
        return .result()
    }
}

// MARK: - Start Call Control Widget

struct StartCallControlWidget: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.pattonium.Hivelink.control.startCall") {
            ControlWidgetButton(action: ControlStartCallIntent()) {
                Label("Start Call", systemImage: "phone.fill")
            }
        }
        .displayName("Start Hivelink Call")
        .description("Quickly start a Hivelink voice session.")
    }
}

// MARK: - Create Task Control Widget

struct CreateTaskControlWidget: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.pattonium.Hivelink.control.createTask") {
            ControlWidgetButton(action: ControlNewTaskIntent()) {
                Label("New Task", systemImage: "plus.circle.fill")
            }
        }
        .displayName("New Hivelink Task")
        .description("Open Hivelink and create a new task.")
    }
}

// MARK: - Pause Incoming Calls Control Widget

struct PauseIncomingCallsControlWidget: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.pattonium.Hivelink.control.pauseCalls") {
            ControlWidgetToggle(
                "Incoming Calls",
                isOn: FocusFilterPreferences.allowIncomingCalls,
                action: ControlSetIncomingCallsIntent()
            ) { isOn in
                Label(
                    isOn ? "Calls On" : "Calls Off",
                    systemImage: isOn ? "phone.badge.checkmark" : "phone.down.fill"
                )
            }
        }
        .displayName("Incoming Calls")
        .description("Toggle whether Hivelink accepts incoming calls.")
    }
}
