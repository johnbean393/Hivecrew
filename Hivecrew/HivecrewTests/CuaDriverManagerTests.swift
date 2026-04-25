//
//  CuaDriverManagerTests.swift
//  HivecrewTests
//
//  Tests for CuaDriverManager: permissions probing and setup requirement.
//

import Foundation
import Testing
import HivecrewCore
@testable import Hivecrew

@Test @MainActor
func managerPermissionsProbed() async {
    let manager = CuaDriverManager.shared
    await manager.refreshStatus()
    // In CI both may be false; on a dev machine they may be true.
    // Just verify the properties are populated without crashing.
    _ = manager.accessibilityGranted
    _ = manager.screenRecordingGranted
}

@Test @MainActor
func managerSetupRequirementReflectsPermissions() async {
    let manager = CuaDriverManager.shared
    await manager.refreshStatus()
    let req = manager.currentSetupRequirement()
    if manager.accessibilityGranted && manager.screenRecordingGranted {
        #expect(req == nil)
    } else {
        #expect(req == .appPermissionsMissing)
    }
}

@Test @MainActor
func managerEngineIsReusable() {
    let manager = CuaDriverManager.shared
    let engine1 = manager.engine
    let engine2 = manager.engine
    #expect(engine1 === engine2)
}
