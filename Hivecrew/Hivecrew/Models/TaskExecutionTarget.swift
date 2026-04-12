//
//  TaskExecutionTarget.swift
//  Hivecrew
//
//  Persisted execution targeting for task scheduling.
//

import Foundation

enum TaskExecutionTargetKind: Int, Codable, Sendable {
    case automatic = 0
    case local = 1
    case peer = 2
    case remoteFirst = 3
}

struct TaskExecutionTarget: Codable, Equatable, Sendable {
    var kind: TaskExecutionTargetKind
    var peerId: String?
    var peerName: String?

    nonisolated static var automatic: TaskExecutionTarget {
        TaskExecutionTarget(kind: .automatic, peerId: nil, peerName: nil)
    }

    nonisolated static var local: TaskExecutionTarget {
        TaskExecutionTarget(kind: .local, peerId: nil, peerName: nil)
    }

    nonisolated static var remoteFirst: TaskExecutionTarget {
        TaskExecutionTarget(kind: .remoteFirst, peerId: nil, peerName: nil)
    }

    nonisolated static func peer(id: String, name: String?) -> TaskExecutionTarget {
        TaskExecutionTarget(kind: .peer, peerId: id, peerName: name)
    }

    var targetPeerId: String? {
        guard kind == .peer else { return nil }
        return peerId
    }

    var displayName: String {
        switch kind {
        case .automatic:
            return "Auto"
        case .remoteFirst:
            return "Remote First"
        case .local:
            return "This Device"
        case .peer:
            return peerName ?? peerId ?? "Specific Peer"
        }
    }
}
