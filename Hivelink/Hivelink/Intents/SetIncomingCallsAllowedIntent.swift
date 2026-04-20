//
//  SetIncomingCallsAllowedIntent.swift
//  Hivelink
//
//  Toggle intent for the Control Center widget that pauses/resumes
//  incoming calls. Reads and writes via the App Group suite so the
//  widget extension can access the same value.
//

import AppIntents
import Foundation

struct SetIncomingCallsAllowedIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Set Incoming Calls Allowed"
    static let description = IntentDescription("Toggles whether Hivelink accepts incoming calls.")

    @Parameter(title: "Allowed")
    var value: Bool

    @MainActor
    func perform() async throws -> some IntentResult {
        FocusFilterPreferences.setAllowIncomingCalls(value)
        return .result()
    }
}
