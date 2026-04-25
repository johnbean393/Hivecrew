//
//  AgentToolConnectionTests.swift
//  HivecrewTests
//
//  Tests for AgentToolConnection protocol and RuntimeObservation.
//

import Foundation
import Testing
import HivecrewCore
@testable import Hivecrew

// MARK: - Mock connections

@MainActor
final class MockTextOnlyConnection: AgentToolConnection {
    var runtimeKind: AgentRuntimeKind { .fast }
    var capabilities: RuntimeCapabilities { .fast }

    func screenshot() async throws -> ScreenshotResult? { nil }

    func observe() async throws -> RuntimeObservation {
        RuntimeObservation(text: "text-only workspace state")
    }

    func openApp(bundleId: String?, appName: String?) async throws {
        throw AgentConnectionError.agentError(code: -1, message: "not available")
    }
    func openFile(path: String, withApp: String?) async throws {
        throw AgentConnectionError.agentError(code: -1, message: "not available")
    }
    func openUrl(_ url: String) async throws {
        throw AgentConnectionError.agentError(code: -1, message: "not available")
    }
    func mouseMove(x: Double, y: Double) async throws {
        throw AgentConnectionError.agentError(code: -1, message: "not available")
    }
    func mouseClick(x: Double, y: Double, button: String, clickType: String) async throws {
        throw AgentConnectionError.agentError(code: -1, message: "not available")
    }
    func mouseDrag(fromX: Double, fromY: Double, toX: Double, toY: Double) async throws {
        throw AgentConnectionError.agentError(code: -1, message: "not available")
    }
    func keyboardType(text: String) async throws {
        throw AgentConnectionError.agentError(code: -1, message: "not available")
    }
    func keyboardKey(key: String, modifiers: [String]) async throws {
        throw AgentConnectionError.agentError(code: -1, message: "not available")
    }
    func scroll(x: Double, y: Double, deltaX: Double, deltaY: Double) async throws {
        throw AgentConnectionError.agentError(code: -1, message: "not available")
    }
    func runShell(command: String, timeout: Double?) async throws -> ShellResult {
        ShellResult(stdout: "ok", stderr: "", exitCode: 0)
    }
    func readFile(path: String) async throws -> FileReadResult {
        .text(content: "contents", fileType: "text")
    }
    func writeFile(path: String, contents: String) async throws {}
    func listDirectory(path: String) async throws -> Any { [] as [String] }
    func moveFile(source: String, destination: String) async throws {}
    func disconnect() {}
}

@MainActor
final class MockVMConnection: AgentToolConnection {
    var runtimeKind: AgentRuntimeKind { .isolatedVM }
    var capabilities: RuntimeCapabilities { .vm }

    func screenshot() async throws -> ScreenshotResult? {
        ScreenshotResult(imageBase64: "AAAA", width: 1920, height: 1080)
    }

    func observe() async throws -> RuntimeObservation {
        let shot = try await screenshot()!
        return RuntimeObservation(
            text: "VM screen",
            screenshot: shot,
            screenWidth: shot.width,
            screenHeight: shot.height
        )
    }

    func openApp(bundleId: String?, appName: String?) async throws {}
    func openFile(path: String, withApp: String?) async throws {}
    func openUrl(_ url: String) async throws {}
    func mouseMove(x: Double, y: Double) async throws {}
    func mouseClick(x: Double, y: Double, button: String, clickType: String) async throws {}
    func mouseDrag(fromX: Double, fromY: Double, toX: Double, toY: Double) async throws {}
    func keyboardType(text: String) async throws {}
    func keyboardKey(key: String, modifiers: [String]) async throws {}
    func scroll(x: Double, y: Double, deltaX: Double, deltaY: Double) async throws {}
    func runShell(command: String, timeout: Double?) async throws -> ShellResult {
        ShellResult(stdout: "", stderr: "", exitCode: 0)
    }
    func readFile(path: String) async throws -> FileReadResult {
        .text(content: "", fileType: "text")
    }
    func writeFile(path: String, contents: String) async throws {}
    func listDirectory(path: String) async throws -> Any { [] as [String] }
    func moveFile(source: String, destination: String) async throws {}
    func disconnect() {}
}

// MARK: - Tests

@Test @MainActor
func textOnlyConnectionReturnsNilScreenshot() async throws {
    let conn: any AgentToolConnection = MockTextOnlyConnection()
    let screenshot = try await conn.screenshot()
    #expect(screenshot == nil)
}

@Test @MainActor
func textOnlyConnectionObservationHasNoScreenshot() async throws {
    let conn: any AgentToolConnection = MockTextOnlyConnection()
    let obs = try await conn.observe()
    #expect(obs.screenshot == nil)
    #expect(obs.screenWidth == nil)
    #expect(obs.screenHeight == nil)
    #expect(!obs.text.isEmpty)
}

@Test @MainActor
func vmConnectionReturnsScreenshot() async throws {
    let conn: any AgentToolConnection = MockVMConnection()
    let screenshot = try await conn.screenshot()
    #expect(screenshot != nil)
    #expect(screenshot?.width == 1920)
    #expect(screenshot?.height == 1080)
}

@Test @MainActor
func vmConnectionObservationIncludesScreenshot() async throws {
    let conn: any AgentToolConnection = MockVMConnection()
    let obs = try await conn.observe()
    #expect(obs.screenshot != nil)
    #expect(obs.screenWidth == 1920)
    #expect(obs.screenHeight == 1080)
}

@Test @MainActor
func runtimeKindAndCapabilitiesMatch() async throws {
    let fast: any AgentToolConnection = MockTextOnlyConnection()
    #expect(fast.runtimeKind == .fast)
    #expect(fast.capabilities == .fast)

    let vm: any AgentToolConnection = MockVMConnection()
    #expect(vm.runtimeKind == .isolatedVM)
    #expect(vm.capabilities == .vm)
}
