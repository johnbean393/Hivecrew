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
    ]

    /// Tools that only make sense inside a VM guest (not App Worker).
    static let vmGuestOnlyTools: Set<AgentMethod> = [
        .traverseAccessibilityTree,
        .healthCheck,
    ]

    /// Tools excluded from App Worker because they use CGEvent at global
    /// screen coordinates, which causes macOS to activate/raise the window
    /// under the cursor — breaking the no-foreground contract.
    /// Use the AX-based `app_click_element` / `app_set_value` instead.
    static let appExcludedTools: Set<AgentMethod> = [
        .mouseMove,
        .mouseClick,
        .mouseDrag,
        .scroll,
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
