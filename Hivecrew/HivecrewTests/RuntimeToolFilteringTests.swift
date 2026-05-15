//
//  RuntimeToolFilteringTests.swift
//  HivecrewTests
//
//  Tests for RuntimeToolFiltering.
//

import Foundation
import Testing
import HivecrewCore
import HivecrewAgentProtocol
@testable import Hivecrew

@Test
func fastExcludesGUITools() {
    let excluded = RuntimeToolFiltering.excludedTools(for: AgentRuntimeKind.fast)

    let expectedExcluded: Set<AgentMethod> = [
        .screenshot, .healthCheck, .traverseAccessibilityTree,
        .openApp, .openFile, .openUrl,
        .mouseMove, .mouseClick, .mouseDrag,
        .keyboardType, .keyboardKey, .scroll,
    ]

    for method in expectedExcluded {
        #expect(excluded.contains(method), "Expected \(method.rawValue) to be excluded for Fast")
    }
}

@Test
func fastKeepsTextTools() {
    let excluded = RuntimeToolFiltering.excludedTools(for: AgentRuntimeKind.fast)

    let expectedPresent: [AgentMethod] = [
        .runShell, .readFile, .writeFile, .listDirectory, .moveFile,
        .wait, .webSearch, .readWebpageContent, .extractInfoFromWebpage,
        .createTodoList, .addTodoItem, .finishTodoItem,
        .generateImage,
        .spawnSubagent, .getSubagentStatus, .awaitSubagents,
    ]

    for method in expectedPresent {
        #expect(!excluded.contains(method), "Expected \(method.rawValue) to NOT be excluded for Fast")
    }
}

@Test
func vmExcludesOnlyAppTools() {
    let excluded = RuntimeToolFiltering.excludedTools(for: AgentRuntimeKind.isolatedVM)
    #expect(excluded == RuntimeToolFiltering.appOnlyTools)
}

@Test
func capabilitiesBasedFilteringMatchesKindBased() {
    let fastByCapabilities = RuntimeToolFiltering.excludedTools(for: RuntimeCapabilities.fast)
    let fastByKind = RuntimeToolFiltering.excludedTools(for: AgentRuntimeKind.fast)
    #expect(fastByCapabilities == fastByKind)

    let vmByCapabilities = RuntimeToolFiltering.excludedTools(for: RuntimeCapabilities.vm)
    let vmByKind = RuntimeToolFiltering.excludedTools(for: AgentRuntimeKind.isolatedVM)
    #expect(vmByCapabilities == vmByKind)
}

// MARK: - App Worker tool filtering

@Test
func appExcludesVMGuestOnlyTools() {
    let excluded = RuntimeToolFiltering.excludedTools(for: AgentRuntimeKind.app)
    #expect(excluded.contains(.traverseAccessibilityTree))
    #expect(excluded.contains(.healthCheck))
}

@Test
func appIncludesAppOnlyTools() {
    let excluded = RuntimeToolFiltering.excludedTools(for: AgentRuntimeKind.app)
    let appTools: [AgentMethod] = [
        .appListApps, .appListWindows, .appSelectWindow,
        .appGetWindowState, .appClickElement, .appSetValue,
        .appSubmitElement, .appOpenURL,
    ]
    for method in appTools {
        #expect(!excluded.contains(method), "Expected \(method.rawValue) to NOT be excluded for App")
    }
}

@Test
func appKeepsDesktopAndFileTools() {
    let excluded = RuntimeToolFiltering.excludedTools(for: AgentRuntimeKind.app)
    let expectedPresent: [AgentMethod] = [
        .openApp, .openFile,
        .appOpenURL,
        .mouseClick, .mouseDrag, .keyboardType, .keyboardKey, .scroll,
        .runShell, .readFile, .writeFile, .listDirectory, .moveFile,
        .generateImage,
    ]
    for method in expectedPresent {
        #expect(!excluded.contains(method), "Expected \(method.rawValue) to NOT be excluded for App")
    }
}

@Test
func appExcludesOnlyToolsThatBypassCuaDriverTargeting() {
    let excluded = RuntimeToolFiltering.excludedTools(for: AgentRuntimeKind.app)
    let expectedExcluded: [AgentMethod] = [
        .openUrl, .mouseMove,
    ]
    for method in expectedExcluded {
        #expect(excluded.contains(method), "Expected \(method.rawValue) to be excluded for App")
    }
    #expect(!excluded.contains(.appOpenURL), "app_open_url should be available for App (dispatches through CuaDriver launch_app URL handoff)")
    #expect(!excluded.contains(.mouseClick), "mouse_click should be available for App (dispatches through CuaDriver pid/window click)")
    #expect(!excluded.contains(.mouseDrag), "mouse_drag should be available for App (dispatches through CuaDriver pid/window drag)")
    #expect(!excluded.contains(.keyboardType), "keyboard_type should be available for App (dispatches through CuaDriver type_text)")
    #expect(!excluded.contains(.keyboardKey), "keyboard_key should be available for App (dispatches through CuaDriver press_key)")
    #expect(!excluded.contains(.scroll), "scroll should be available for App (dispatches through CuaDriver's background scroll tool)")
}

@Test
func fastExcludesAppOnlyTools() {
    let excluded = RuntimeToolFiltering.excludedTools(for: AgentRuntimeKind.fast)
    let appTools: [AgentMethod] = [
        .appListApps, .appListWindows, .appSelectWindow,
        .appGetWindowState, .appClickElement, .appSetValue,
        .appSubmitElement, .appOpenURL,
    ]
    for method in appTools {
        #expect(excluded.contains(method), "Expected \(method.rawValue) to be excluded for Fast")
    }
}

@Test
func vmExcludesAppOnlyTools() {
    let excluded = RuntimeToolFiltering.excludedTools(for: AgentRuntimeKind.isolatedVM)
    let appTools: [AgentMethod] = [
        .appListApps, .appListWindows, .appSelectWindow,
        .appGetWindowState, .appClickElement, .appSetValue,
        .appSubmitElement, .appOpenURL,
    ]
    for method in appTools {
        #expect(excluded.contains(method), "Expected \(method.rawValue) to be excluded for VM")
    }
}
