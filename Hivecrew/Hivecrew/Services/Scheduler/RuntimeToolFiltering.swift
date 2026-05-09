//
//  RuntimeToolFiltering.swift
//  Hivecrew
//
//  Returns the set of AgentMethods to exclude based on runtime capabilities.
//

import Foundation
import HivecrewCore
import HivecrewAgentProtocol

enum RuntimeToolFiltering {

    /// GUI/vision tools that Fast Worker must never expose.
    static let fastExcludedTools: Set<AgentMethod> = [
        .screenshot,
        .healthCheck,
        .traverseAccessibilityTree,
        .openApp,
        .openFile,
        .openUrl,
        .mouseMove,
        .mouseClick,
        .mouseDrag,
        .keyboardType,
        .keyboardKey,
        .scroll,
    ]

    /// App Worker facade tools — only available when runtime is .app.
    static let appOnlyTools: Set<AgentMethod> = [
        .appListApps,
        .appListWindows,
        .appSelectWindow,
        .appGetWindowState,
        .appClickElement,
        .appSetValue,
        .appSubmitElement,
        .appOpenURL,
    ]

    /// Tools that only make sense inside a VM guest (not App Worker).
    static let vmGuestOnlyTools: Set<AgentMethod> = [
        .traverseAccessibilityTree,
        .healthCheck,
    ]

    /// Tools excluded from App Worker because they bypass the CuaDriver
    /// background-control contract or expose primitives that are too easy to
    /// route to the user's foreground app. Use the CuaDriver-backed
    /// `app_*` facade tools instead.
    /// `open_url` is excluded because default URL handlers can activate apps;
    /// use `open_app` plus app/window tools for GUI browser work.
    /// `keyboard_key` is excluded because even pid-targeted key events can
    /// cause apps such as Chrome to activate themselves. Use semantic app_*
    /// actions, especially `app_submit_element`, instead.
    /// `scroll` is kept: App Worker dispatches it through CuaDriver's
    /// background scroll tool.
    static let appExcludedTools: Set<AgentMethod> = [
        .openUrl,
        .mouseMove,
        .mouseClick,
        .mouseDrag,
        .keyboardKey,
    ]

    /// Returns the set of `AgentMethod`s that should be excluded from the
    /// tool schema for the given runtime capabilities.
    static func excludedTools(for capabilities: RuntimeCapabilities) -> Set<AgentMethod> {
        if !capabilities.desktopObservation && !capabilities.desktopInput {
            return fastExcludedTools.union(appOnlyTools)
        }
        if capabilities.hostAppAccess && !capabilities.isolatedOS {
            return vmGuestOnlyTools.union(appExcludedTools)
        }
        return appOnlyTools
    }

    /// Convenience overload keyed by runtime kind.
    static func excludedTools(for kind: AgentRuntimeKind) -> Set<AgentMethod> {
        switch kind {
        case .fast:
            return fastExcludedTools.union(appOnlyTools)
        case .app:
            return vmGuestOnlyTools.union(appExcludedTools)
        case .isolatedVM:
            return appOnlyTools
        }
    }
}
