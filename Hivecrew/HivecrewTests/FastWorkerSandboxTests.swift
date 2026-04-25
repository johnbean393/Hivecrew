//
//  FastWorkerSandboxTests.swift
//  HivecrewTests
//
//  Tests for FastWorkerSession path validation (approved-root sandbox).
//

import Foundation
import Testing
import HivecrewCore
@testable import Hivecrew

@MainActor
private func makeTempSession() throws -> FastWorkerSession {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("HivecrewTests-\(UUID().uuidString)", isDirectory: true)
    let paths = FastWorkerPaths(sessionId: "test-session", parentRoot: tempDir)
    try paths.createLayout()
    let session = FastWorkerSession(paths: paths)
    try session.initialize()
    return session
}

@Test @MainActor
func pathInsideWorkspaceIsAllowed() throws {
    let session = try makeTempSession()
    let resolved = try session.validatePath("workspace/test.txt")
    #expect(resolved.path.contains("workspace"))
}

@Test @MainActor
func pathInsideInboxIsAllowed() throws {
    let session = try makeTempSession()
    let resolved = try session.validatePath(session.paths.inbox.appendingPathComponent("file.txt").path)
    #expect(resolved.path.contains("inbox"))
}

@Test @MainActor
func pathInsideOutboxIsAllowed() throws {
    let session = try makeTempSession()
    let resolved = try session.validatePath(session.paths.outbox.appendingPathComponent("output.pdf").path)
    #expect(resolved.path.contains("outbox"))
}

@Test @MainActor
func pathOutsideRootsIsRejected() throws {
    let session = try makeTempSession()
    #expect(throws: FastWorkerSessionError.self) {
        try session.validatePath("/etc/passwd")
    }
}

@Test @MainActor
func pathTraversalIsRejected() throws {
    let session = try makeTempSession()
    #expect(throws: FastWorkerSessionError.self) {
        try session.validatePath(session.paths.workspace.path + "/../../etc/passwd")
    }
}

@Test @MainActor
func isPathAllowedReturnsFalseForExternalPaths() throws {
    let session = try makeTempSession()
    #expect(!session.isPathAllowed("/usr/bin/bash"))
    #expect(session.isPathAllowed(session.paths.workspace.appendingPathComponent("file.txt").path))
}

@Test @MainActor
func localAccessGrantExpandsApprovedRoots() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("HivecrewTests-\(UUID().uuidString)", isDirectory: true)
    let paths = FastWorkerPaths(sessionId: "test-grant", parentRoot: tempDir)
    try paths.createLayout()

    let grantDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("HivecrewTests-Grant-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: grantDir, withIntermediateDirectories: true)

    let grant = LocalAccessGrant(
        scopeKind: .folder,
        displayName: "Test Grant",
        rootPath: grantDir.path,
        origin: .explicitGrant,
        accessMode: .readWrite
    )
    let session = FastWorkerSession(paths: paths, localAccessGrants: [grant])
    try session.initialize()

    let resolved = try session.validatePath(grantDir.appendingPathComponent("doc.txt").path)
    #expect(resolved.path.hasPrefix(grantDir.path))

    try? FileManager.default.removeItem(at: grantDir)
}
