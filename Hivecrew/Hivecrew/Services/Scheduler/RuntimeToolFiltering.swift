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

    /// App Worker-specific facade tools — never available in Fast or VM.
    /// Some of these may still be excluded from App Worker below if they
    /// violate the no-foreground contract in practice.
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
    /// background-control contract.
    /// `open_url` routes through default URL handlers and does not let the
    /// agent name the target app. Use `app_open_url`, which maps to
    /// CuaDriver's `launch_app({ urls: [...] })` handoff instead.
    /// `mouse_move` moves the real cursor and has no target-window action.
    /// The remaining desktop input tools are kept because App Worker dispatches
    /// them through CuaDriver with the selected pid/window.
    static let appExcludedTools: Set<AgentMethod> = [
        .openUrl,
        .mouseMove,
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
