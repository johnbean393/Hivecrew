//
//  FocusFilterPreferences.swift
//  Hivelink
//
//  Centralizes Focus Filter preference reads/writes via the App Group
//  suite so both the main app and the widget extension share state.
//  Must stay in sync with HivelinkWidgets/FocusFilterPreferences.swift.
//

import Foundation

enum FocusFilterPreferences {
    private static let suiteName = "group.com.pattonium.Hivelink"
    private static let allowNotificationsKey = "focusFilter.allowNotifications"
    private static let allowIncomingCallsKey = "focusFilter.allowIncomingCalls"

    private static var suite: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    static var allowNotifications: Bool {
        guard suite.object(forKey: allowNotificationsKey) != nil else { return true }
        return suite.bool(forKey: allowNotificationsKey)
    }

    static func setAllowNotifications(_ value: Bool) {
        suite.set(value, forKey: allowNotificationsKey)
        UserDefaults.standard.set(value, forKey: allowNotificationsKey)
    }

    static var allowIncomingCalls: Bool {
        guard suite.object(forKey: allowIncomingCallsKey) != nil else { return true }
        return suite.bool(forKey: allowIncomingCallsKey)
    }

    static func setAllowIncomingCalls(_ value: Bool) {
        suite.set(value, forKey: allowIncomingCallsKey)
        UserDefaults.standard.set(value, forKey: allowIncomingCallsKey)
    }
}
