//
//  AppWorkerSandboxTests.swift
//  HivecrewTests
//
//  Tests for WorkspaceSandbox and AppWorkerSession path confinement.
//

import Foundation
import Testing
import HivecrewCore
@testable import Hivecrew

// MARK: - WorkspaceSandbox

@Test
func sandboxAcceptsPathInsideRoot() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("sandbox-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let sandbox = WorkspaceSandbox(root: root, sessionDirectories: [root])
    let resolved = try sandbox.validatePath(root.appendingPathComponent("file.txt").path)
    #expect(resolved.path.hasSuffix("file.txt"))
}

@Test
func sandboxRejectsPathOutsideRoot() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("sandbox-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let sandbox = WorkspaceSandbox(root: root, sessionDirectories: [root])
    #expect(throws: WorkspaceSandboxError.self) {
        try sandbox.validatePath("/etc/passwd")
    }
}

@Test
func sandboxIsPathAllowedReturnsBool() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("sandbox-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let sandbox = WorkspaceSandbox(root: root, sessionDirectories: [root])
    #expect(sandbox.isPathAllowed(root.appendingPathComponent("ok.txt").path))
    #expect(!sandbox.isPathAllowed("/etc/passwd"))
}

@Test
func sandboxWithGrantsExpandsRoots() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("sandbox-test-\(UUID().uuidString)", isDirectory: true)
    let extra = FileManager.default.temporaryDirectory
        .appendingPathComponent("sandbox-extra-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: extra)
    }

    let grant = LocalAccessGrant(scopeKind: .folder, displayName: "extra", rootPath: extra.path, origin: .explicitGrant)
    let sandbox = WorkspaceSandbox(root: root, sessionDirectories: [root], grants: [grant])
    #expect(sandbox.isPathAllowed(extra.appendingPathComponent("data.csv").path))
}

// MARK: - AppWorkerSession sandbox parity

@Test @MainActor
func appWorkerSessionUsesWorkspaceSandbox() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("HivecrewTests-AW-\(UUID().uuidString)", isDirectory: true)
    let paths = FastWorkerPaths(sessionId: "test-sandbox", parentRoot: tempDir)
    try paths.createLayout()

    let session = AppWorkerSession(paths: paths)
    try session.initialize()

    let workspacePath = paths.workspace.appendingPathComponent("test.txt").path
    let resolved = try session.validatePath(workspacePath)
    #expect(resolved.lastPathComponent == "test.txt")

    #expect(!session.isPathAllowed("/etc/passwd"))
}
