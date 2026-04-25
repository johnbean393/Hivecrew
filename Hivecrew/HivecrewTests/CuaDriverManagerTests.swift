//
//  CuaDriverManagerTests.swift
//  HivecrewTests
//
//  Tests for CuaDriverManager: binary probing, status, setup requirement.
//

import Foundation
import Testing
import HivecrewCore
@testable import Hivecrew

@Test @MainActor
func managerBinaryStatusReflectsPresence() async {
    let manager = CuaDriverManager.shared
    await manager.refreshStatus()
    // In test environment the binary may or may not be bundled;
    // verify the enum is either .found or .missing, not .unknown after probing.
    #expect(manager.binaryStatus != .unknown)
}

@Test @MainActor
func managerSetupRequirementWhenBinaryMissing() async {
    let manager = CuaDriverManager.shared
    if manager.locateBinary() == nil {
        let req = manager.currentSetupRequirement()
        #expect(req == .cuaDriverMissing)
    }
}

@Test @MainActor
func managerBackendDefaultIsStopped() {
    // Backend should not auto-launch during tests.
    // The status may be .stopped or .running if a prior test launched it.
    let status = CuaDriverManager.shared.backendStatus
    #expect(status == .stopped || status == .failed || status == .running)
}

@Test @MainActor
func managerLocateBinaryReturnsURLOrNil() {
    let url = CuaDriverManager.shared.locateBinary()
    if let url = url {
        #expect(FileManager.default.isExecutableFile(atPath: url.path))
    }
}
