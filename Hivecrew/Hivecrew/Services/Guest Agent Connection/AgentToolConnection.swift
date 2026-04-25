//
//  AgentToolConnection.swift
//  Hivecrew
//
//  Runtime-neutral protocol for agent tool execution across
//  Fast Worker, App Worker, and Isolated VM runtimes.
//

import Foundation
import HivecrewCore

// MARK: - Runtime Observation

struct RuntimeObservation: Sendable {
    var text: String
    var screenshot: ScreenshotResult?
    var screenWidth: Int?
    var screenHeight: Int?
    var metadata: [String: String]

    init(
        text: String = "",
        screenshot: ScreenshotResult? = nil,
        screenWidth: Int? = nil,
        screenHeight: Int? = nil,
        metadata: [String: String] = [:]
    ) {
        self.text = text
        self.screenshot = screenshot
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.metadata = metadata
    }
}

// MARK: - Agent Tool Connection Protocol

@MainActor
protocol AgentToolConnection: AnyObject {
    var runtimeKind: AgentRuntimeKind { get }
    var capabilities: RuntimeCapabilities { get }

    func screenshot() async throws -> ScreenshotResult?
    func observe() async throws -> RuntimeObservation

    func openApp(bundleId: String?, appName: String?) async throws
    func openFile(path: String, withApp: String?) async throws
    func openUrl(_ url: String) async throws

    func mouseMove(x: Double, y: Double) async throws
    func mouseClick(x: Double, y: Double, button: String, clickType: String) async throws
    func mouseDrag(fromX: Double, fromY: Double, toX: Double, toY: Double) async throws
    func keyboardType(text: String) async throws
    func keyboardKey(key: String, modifiers: [String]) async throws
    func scroll(x: Double, y: Double, deltaX: Double, deltaY: Double) async throws

    func runShell(command: String, timeout: Double?) async throws -> ShellResult
    func readFile(path: String) async throws -> FileReadResult
    func writeFile(path: String, contents: String) async throws
    func listDirectory(path: String) async throws -> Any
    func moveFile(source: String, destination: String) async throws

    func disconnect()
}

// MARK: - Default parameter values

extension AgentToolConnection {
    func runShell(command: String) async throws -> ShellResult {
        try await runShell(command: command, timeout: nil)
    }
}
