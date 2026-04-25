//
//  CuaDriverConnectionTests.swift
//  HivecrewTests
//
//  Tests for CuaDriverConnection: runtime properties, observation,
//  file operations, and shell within sandbox.
//

import Foundation
import Testing
import HivecrewCore
@testable import Hivecrew

// MARK: - Helpers

@MainActor
private func makeAppWorkerSession() throws -> AppWorkerSession {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("HivecrewTests-AppConn-\(UUID().uuidString)", isDirectory: true)
    let paths = FastWorkerPaths(sessionId: "test-app", parentRoot: tempDir)
    try paths.createLayout()
    let session = AppWorkerSession(paths: paths)
    try session.initialize()
    return session
}

// MARK: - Runtime properties

@Test @MainActor
func appConnectionRuntimeKind() throws {
    let session = try makeAppWorkerSession()
    // We can't create a real MCPClient in tests, but we can verify the
    // static properties via a minimal approach — check the type constants.
    #expect(AgentRuntimeKind.app.displayName == "App Worker")
    #expect(RuntimeCapabilities.app.desktopObservation == true)
    #expect(RuntimeCapabilities.app.desktopInput == true)
    #expect(RuntimeCapabilities.app.hostAppAccess == true)
    #expect(RuntimeCapabilities.app.shell == true)
    #expect(RuntimeCapabilities.app.filesystem == true)
    #expect(RuntimeCapabilities.app.isolatedOS == false)
    _ = session
}

// MARK: - App Worker session sandbox

@Test @MainActor
func appSessionRejectsPathOutsideRoots() throws {
    let session = try makeAppWorkerSession()
    #expect(throws: WorkspaceSandboxError.self) {
        try session.validatePath("/etc/passwd")
    }
    #expect(throws: WorkspaceSandboxError.self) {
        try session.validatePath("/tmp/evil.txt")
    }
}

@Test @MainActor
func appSessionAcceptsPathInsideWorkspace() throws {
    let session = try makeAppWorkerSession()
    let workspacePath = session.paths.workspace.appendingPathComponent("test.txt").path
    let resolved = try session.validatePath(workspacePath)
    #expect(resolved.lastPathComponent == "test.txt")
}

// MARK: - File operations via AppWorkerSession

@Test @MainActor
func appSessionWriteAndRead() throws {
    let session = try makeAppWorkerSession()
    let filePath = session.paths.workspace.appendingPathComponent("hello.txt").path
    let fm = FileManager.default
    let resolved = try session.validatePath(filePath)
    try "Hello, App Worker!".write(to: resolved, atomically: true, encoding: .utf8)
    let content = try String(contentsOf: resolved, encoding: .utf8)
    #expect(content == "Hello, App Worker!")
}

// MARK: - Text observation

@Test @MainActor
func appSessionObservationIsTextOnly() throws {
    let session = try makeAppWorkerSession()
    let obs = session.textObservation(todoManager: nil)
    #expect(obs.screenshot == nil)
    #expect(obs.text.contains("App Worker"))
    #expect(obs.metadata["runtime"] == "app")
}
