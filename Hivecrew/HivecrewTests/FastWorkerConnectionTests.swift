//
//  FastWorkerConnectionTests.swift
//  HivecrewTests
//
//  Tests for FastWorkerConnection: text-only observation, GUI throws, file ops.
//

import Foundation
import Testing
import HivecrewCore
@testable import Hivecrew

@MainActor
private func makeConnection() throws -> FastWorkerConnection {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("HivecrewTests-FWC-\(UUID().uuidString)", isDirectory: true)
    let paths = FastWorkerPaths(sessionId: "test-fwc", parentRoot: tempDir)
    try paths.createLayout()
    let session = FastWorkerSession(paths: paths)
    try session.initialize()
    return FastWorkerConnection(session: session)
}

// MARK: - Observation

@Test @MainActor
func fastConnectionReturnsNilScreenshot() async throws {
    let conn = try makeConnection()
    let shot = try await conn.screenshot()
    #expect(shot == nil)
}

@Test @MainActor
func fastConnectionObservationIsTextOnly() async throws {
    let conn = try makeConnection()
    let obs = try await conn.observe()
    #expect(obs.screenshot == nil)
    #expect(obs.screenWidth == nil)
    #expect(obs.screenHeight == nil)
    #expect(!obs.text.isEmpty)
    #expect(obs.text.contains("Fast Worker"))
}

@Test @MainActor
func fastConnectionRuntimeProperties() throws {
    let conn = try makeConnection()
    #expect(conn.runtimeKind == .fast)
    #expect(conn.capabilities == .fast)
    #expect(conn.capabilities.desktopObservation == false)
    #expect(conn.capabilities.desktopInput == false)
    #expect(conn.capabilities.shell == true)
    #expect(conn.capabilities.filesystem == true)
}

// MARK: - GUI throws

@Test @MainActor
func fastConnectionOpenAppThrows() async throws {
    let conn = try makeConnection()
    await #expect(throws: FastWorkerConnectionError.self) {
        try await conn.openApp(bundleId: "com.apple.Safari", appName: nil)
    }
}

@Test @MainActor
func fastConnectionMouseClickThrows() async throws {
    let conn = try makeConnection()
    await #expect(throws: FastWorkerConnectionError.self) {
        try await conn.mouseClick(x: 100, y: 100, button: "left", clickType: "single")
    }
}

@Test @MainActor
func fastConnectionKeyboardTypeThrows() async throws {
    let conn = try makeConnection()
    await #expect(throws: FastWorkerConnectionError.self) {
        try await conn.keyboardType(text: "hello")
    }
}

@Test @MainActor
func fastConnectionScrollThrows() async throws {
    let conn = try makeConnection()
    await #expect(throws: FastWorkerConnectionError.self) {
        try await conn.scroll(x: 0, y: 0, deltaX: 0, deltaY: 5)
    }
}

// MARK: - File operations

@Test @MainActor
func fastConnectionWriteAndReadFile() async throws {
    let conn = try makeConnection()
    let path = conn.session.paths.workspace.appendingPathComponent("test.txt").path
    try await conn.writeFile(path: path, contents: "Hello, Fast Worker!")
    let result = try await conn.readFile(path: path)
    if case .text(let content, _) = result {
        #expect(content == "Hello, Fast Worker!")
    } else {
        Issue.record("Expected text result")
    }
}

@Test @MainActor
func fastConnectionListDirectory() async throws {
    let conn = try makeConnection()
    let path = conn.session.paths.workspace.appendingPathComponent("test-ls.txt").path
    try await conn.writeFile(path: path, contents: "data")
    let entries = try await conn.listDirectory(path: conn.session.paths.workspace.path)
    #expect(entries is [[String: Any]])
}

@Test @MainActor
func fastConnectionMoveFile() async throws {
    let conn = try makeConnection()
    let src = conn.session.paths.workspace.appendingPathComponent("move-src.txt").path
    let dst = conn.session.paths.workspace.appendingPathComponent("move-dst.txt").path
    try await conn.writeFile(path: src, contents: "data")
    try await conn.moveFile(source: src, destination: dst)
    let result = try await conn.readFile(path: dst)
    if case .text(let content, _) = result {
        #expect(content == "data")
    } else {
        Issue.record("Expected text result")
    }
}

@Test @MainActor
func fastConnectionRejectsPathOutsideRoots() async throws {
    let conn = try makeConnection()
    await #expect(throws: FastWorkerSessionError.self) {
        try await conn.readFile(path: "/etc/passwd")
    }
    await #expect(throws: FastWorkerSessionError.self) {
        try await conn.writeFile(path: "/tmp/evil.txt", contents: "hack")
    }
}

// MARK: - Shell

@Test @MainActor
func fastConnectionRunShell() async throws {
    let conn = try makeConnection()
    let result = try await conn.runShell(command: "echo hello", timeout: 10)
    #expect(result.exitCode == 0)
    #expect(result.stdout.contains("hello"))
}
