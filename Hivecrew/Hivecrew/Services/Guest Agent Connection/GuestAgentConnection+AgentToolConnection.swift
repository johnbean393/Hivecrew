//
//  GuestAgentConnection+AgentToolConnection.swift
//  Hivecrew
//
//  Conformance adapter: makes the existing VM guest agent connection
//  usable through the runtime-neutral AgentToolConnection protocol.
//

import Foundation
import HivecrewCore

extension GuestAgentConnection: AgentToolConnection {

    var runtimeKind: AgentRuntimeKind { .isolatedVM }

    var capabilities: RuntimeCapabilities { .vm }

    // MARK: - Observation

    func screenshot() async throws -> ScreenshotResult? {
        try await vmScreenshot()
    }

    func observe() async throws -> RuntimeObservation {
        let shot = try await vmScreenshot()
        return RuntimeObservation(
            text: "VM screen \(shot.width)x\(shot.height)",
            screenshot: shot,
            screenWidth: shot.width,
            screenHeight: shot.height
        )
    }

    // MARK: - Filesystem stubs (VM uses run_shell wrappers in ToolExecutor)

    func writeFile(path: String, contents: String) async throws {
        throw AgentConnectionError.agentError(
            code: -32601,
            message: "writeFile not implemented for VM runtime; use run_shell"
        )
    }

    func listDirectory(path: String) async throws -> Any {
        throw AgentConnectionError.agentError(
            code: -32601,
            message: "listDirectory not implemented for VM runtime; use run_shell"
        )
    }
}
