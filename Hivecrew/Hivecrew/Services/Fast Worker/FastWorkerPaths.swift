//
//  FastWorkerPaths.swift
//  Hivecrew
//
//  Typed wrapper for the Fast Worker session directory layout.
//

import Foundation
import HivecrewShared

struct FastWorkerPaths: Sendable {
    let sessionId: String
    let root: URL

    var inbox: URL { root.appendingPathComponent("inbox", isDirectory: true) }
    var workspace: URL { root.appendingPathComponent("workspace", isDirectory: true) }
    var outbox: URL { root.appendingPathComponent("outbox", isDirectory: true) }
    var screenshots: URL { root.appendingPathComponent("screenshots", isDirectory: true) }
    var writeback: URL { root.appendingPathComponent("writeback", isDirectory: true) }
    var trace: URL { root.appendingPathComponent("trace.jsonl") }
    var plan: URL { root.appendingPathComponent("plan.md") }
    var planState: URL { root.appendingPathComponent("plan_state.json") }

    var allDirectories: [URL] {
        [inbox, workspace, outbox, screenshots, writeback]
    }

    init(sessionId: String) {
        self.sessionId = sessionId
        self.root = AppPaths.sessionDirectory(id: sessionId)
    }

    init(sessionId: String, parentRoot: URL) {
        self.sessionId = sessionId
        self.root = parentRoot
    }

    func createLayout() throws {
        let fm = FileManager.default
        for dir in allDirectories {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    func subagentPaths(subagentId: String) -> FastWorkerPaths {
        let subRoot = root
            .appendingPathComponent("subagents", isDirectory: true)
            .appendingPathComponent(subagentId, isDirectory: true)
        return FastWorkerPaths(sessionId: subagentId, parentRoot: subRoot)
    }
}
