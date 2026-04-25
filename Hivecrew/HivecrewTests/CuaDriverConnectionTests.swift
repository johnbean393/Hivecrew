//
//  CuaDriverConnectionTests.swift
//  HivecrewTests
//
//  Tests for CuaDriverConnection: runtime properties, observation,
//  file operations, sandbox, and tree-markdown parsing.
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

// MARK: - TreeMarkdownParser

@Test func treeMarkdownParserExtractsIndexedElements() {
    let markdown = """
    - AXApplication "System Settings"
      - AXWindow "General"
        - [0] AXButton "Close"
        - [1] AXButton "Minimize"
        - AXGroup
          - [2] AXStaticText "General"
          - [3] AXTextField "Search" = "hello"
    """
    let elements = TreeMarkdownParser.parseElements(markdown)
    #expect(elements.count == 4)
    #expect(elements[0].index == 0)
    #expect(elements[0].role == "AXButton")
    #expect(elements[0].label == "Close")
    #expect(elements[1].index == 1)
    #expect(elements[1].role == "AXButton")
    #expect(elements[1].label == "Minimize")
    #expect(elements[2].index == 2)
    #expect(elements[2].role == "AXStaticText")
    #expect(elements[2].label == "General")
    #expect(elements[3].index == 3)
    #expect(elements[3].role == "AXTextField")
    #expect(elements[3].label == "Search")
    #expect(elements[3].value == "hello")
}

@Test func treeMarkdownParserHandlesEmptyTree() {
    let markdown = ""
    let elements = TreeMarkdownParser.parseElements(markdown)
    #expect(elements.isEmpty)
}

@Test func treeMarkdownParserSkipsNonIndexedLines() {
    let markdown = """
    - AXApplication "Finder"
      - AXWindow "Desktop"
        - AXGroup
          - [0] AXButton "New Folder"
    """
    let elements = TreeMarkdownParser.parseElements(markdown)
    #expect(elements.count == 1)
    #expect(elements[0].index == 0)
    #expect(elements[0].role == "AXButton")
    #expect(elements[0].label == "New Folder")
}

@Test func treeMarkdownParserHandlesActionsAndDisabled() {
    let markdown = """
    - [0] AXButton "Submit" actions=[AXShowMenu, AXCopy]
    - [1] AXCheckBox "Agree" DISABLED
    """
    let elements = TreeMarkdownParser.parseElements(markdown)
    #expect(elements.count == 2)
    #expect(elements[0].role == "AXButton")
    #expect(elements[0].label == "Submit")
    #expect(elements[1].role == "AXCheckBox")
    #expect(elements[1].label == "Agree")
}
