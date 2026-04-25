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
    ]
    for method in appTools {
        #expect(!excluded.contains(method), "Expected \(method.rawValue) to NOT be excluded for App")
    }
}

@Test
func appKeepsDesktopAndFileTools() {
    let excluded = RuntimeToolFiltering.excludedTools(for: AgentRuntimeKind.app)
    let expectedPresent: [AgentMethod] = [
        .openApp, .openFile, .openUrl,
        .mouseClick, .keyboardType, .scroll,
        .runShell, .readFile, .writeFile, .listDirectory, .moveFile,
    ]
    for method in expectedPresent {
        #expect(!excluded.contains(method), "Expected \(method.rawValue) to NOT be excluded for App")
    }
}

@Test
func fastExcludesAppOnlyTools() {
    let excluded = RuntimeToolFiltering.excludedTools(for: AgentRuntimeKind.fast)
    let appTools: [AgentMethod] = [
        .appListApps, .appListWindows, .appSelectWindow,
        .appGetWindowState, .appClickElement, .appSetValue,
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
    ]
    for method in appTools {
        #expect(excluded.contains(method), "Expected \(method.rawValue) to be excluded for VM")
    }
}
