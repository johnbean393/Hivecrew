//
//  TaskExecutionTarget.swift
//  Hivecrew
//
//  Persisted execution targeting for task scheduling.
//

import Foundation

public enum TaskExecutionTargetKind: Int, Codable, Sendable {
    case automatic = 0
    case local = 1
    case peer = 2
    case remoteFirst = 3
}

public struct TaskExecutionTarget: Codable, Equatable, Sendable {
    public var kind: TaskExecutionTargetKind
    public var peerId: String?
    public var peerName: String?

    public init(kind: TaskExecutionTargetKind, peerId: String?, peerName: String?) {
        self.kind = kind
        self.peerId = peerId
        self.peerName = peerName
    }

    public nonisolated static var automatic: TaskExecutionTarget {
        TaskExecutionTarget(kind: .automatic, peerId: nil, peerName: nil)
    }

    public nonisolated static var local: TaskExecutionTarget {
        TaskExecutionTarget(kind: .local, peerId: nil, peerName: nil)
    }

    public nonisolated static var remoteFirst: TaskExecutionTarget {
        TaskExecutionTarget(kind: .remoteFirst, peerId: nil, peerName: nil)
    }

    public nonisolated static func peer(id: String, name: String?) -> TaskExecutionTarget {
        TaskExecutionTarget(kind: .peer, peerId: id, peerName: name)
    }

    public var targetPeerId: String? {
        guard kind == .peer else { return nil }
        return peerId
    }

    public var displayName: String {
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
