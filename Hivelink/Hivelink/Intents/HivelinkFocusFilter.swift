//
//  HivelinkFocusFilter.swift
//  Hivelink
//
//  Focus Filter intent that lets users control Hivelink's notification
//  and incoming call behavior when a system Focus mode is active.
//

import AppIntents

struct HivelinkFocusFilter: SetFocusFilterIntent {
    static var title: LocalizedStringResource = "Hivelink Focus Filter"
    static var description: IntentDescription? = "Controls Hivelink behavior during Focus modes."

    @Parameter(title: "Allow Notifications", default: true)
    var allowNotifications: Bool

    @Parameter(title: "Allow Incoming Calls", default: true)
    var allowIncomingCalls: Bool

    func perform() async throws -> some IntentResult {
        let defaults = UserDefaults.standard
        defaults.set(allowNotifications, forKey: "focusFilter.allowNotifications")
        defaults.set(allowIncomingCalls, forKey: "focusFilter.allowIncomingCalls")
        return .result()
    }
}
