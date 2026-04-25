//
//  RuntimeRoutingPolicy.swift
//  Hivecrew
//
//  Pure-function routing logic for choosing runtime kind + device.
//  Testable without TaskService or SwiftData.
//

import Foundation
import HivecrewCore

// MARK: - Data-local constraint

enum DataLocalConstraint: Equatable {
    case none
    case requiresLocalDevice
}

// MARK: - Eligibility result

enum DeviceEligibilityResult: Equatable {
    case localOnly
    case peer(peerId: String)
    case requiresDeviceSelection(peerIds: [String])
    case noEligible(reason: RuntimeSetupRequirement)
}

// MARK: - Peer runtime info (protocol so tests can supply stubs)

protocol RuntimeRoutingPeerInfo {
    var peerId: String { get }
    var peerName: String? { get }
    var isOnline: Bool { get }
    var providerMatch: Bool { get }
    func runtimeSupported(_ kind: AgentRuntimeKind) -> Bool
    func runtimeAvailableSlots(_ kind: AgentRuntimeKind) -> Int
    func runtimeSetupReady(_ kind: AgentRuntimeKind) -> Bool
}

// MARK: - Policy

struct RuntimeRoutingPolicy {

    // MARK: - Host-specific detection

    private static let hostSpecificPattern: NSRegularExpression? = {
        let terms = [
            "my safari", "my mail", "my browser", "my account",
            "my calendar", "my notes", "my finder", "my figma",
            "my keynote", "my preview", "my app",
            "my logged.in", "my browser profile", "my session",
            "use my", "open my", "this mac", "this window",
            "on my screen", "on my mac", "on my desktop",
        ]
        let pattern = terms
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        return try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()

    /// Whether the task description implies the user's personal host state.
    static func isHostSpecificRequest(description: String) -> Bool {
        guard let regex = hostSpecificPattern else { return false }
        let range = NSRange(description.startIndex..., in: description)
        return regex.firstMatch(in: description, range: range) != nil
    }

    /// Combines requirement flags and description heuristic.
    static func isHostSpecific(
        requirement: TaskRuntimeRequirement,
        description: String
    ) -> Bool {
        if requirement.requiresHostSpecificState { return true }
        if requirement.requiresSpecificDevice { return true }
        if requirement.requiredCapabilities.hostAppAccess {
            return isHostSpecificRequest(description: description)
        }
        return false
    }

    // MARK: - Data-local constraint

    static func dataLocalConstraint(for task: TaskRecord) -> DataLocalConstraint {
        if !task.localAccessGrants.isEmpty { return .requiresLocalDevice }
        if task.hasPendingWriteback { return .requiresLocalDevice }
        if let applied = task.appliedWritebackPaths, !applied.isEmpty {
            return .requiresLocalDevice
        }
        return .none
    }

    // MARK: - Eligible device selection

    /// Chooses a device (local or peer) for the given task + runtime requirement.
    ///
    /// - Parameters:
    ///   - deviceTarget: The user-selected device target (auto / local / peer / remoteFirst).
    ///   - requirement: Runtime requirement from the classifier.
    ///   - description: Task description (for host-specific heuristic).
    ///   - localCanRun: Whether the local Mac can run the assigned runtime right now.
    ///   - isAppWorkerReady: Whether App Worker setup is complete on the local Mac.
    ///   - peers: Runtime-aware peer info from ClusterManager.
    static func eligibleDevice(
        deviceTarget: TaskExecutionTarget,
        assignedRuntime: AgentRuntimeKind,
        requirement: TaskRuntimeRequirement,
        description: String,
        dataLocalConstraint: DataLocalConstraint,
        localCanRun: Bool,
        isAppWorkerReady: Bool,
        peers: [any RuntimeRoutingPeerInfo]
    ) -> DeviceEligibilityResult {
        let hostSpecific = isHostSpecific(requirement: requirement, description: description)

        // Host-specific or data-local tasks must stay on the correct device.
        if hostSpecific || dataLocalConstraint == .requiresLocalDevice {
            switch deviceTarget.kind {
            case .local, .automatic:
                if localCanRun { return .localOnly }
                if assignedRuntime == .app && !isAppWorkerReady {
                    return .noEligible(reason: .appPermissionsMissing)
                }
                return .noEligible(reason: .noEligibleDevice)

            case .peer:
                if let peerId = deviceTarget.targetPeerId {
                    let peer = peers.first { $0.peerId == peerId }
                    if let peer, peer.isOnline, peer.runtimeSupported(assignedRuntime),
                       peer.runtimeSetupReady(assignedRuntime),
                       peer.runtimeAvailableSlots(assignedRuntime) > 0,
                       peer.providerMatch {
                        return .peer(peerId: peerId)
                    }
                }
                return .noEligible(reason: .noEligibleDevice)

            case .remoteFirst:
                // For host-specific tasks from Hivelink with no explicit device,
                // check how many peers can serve the runtime.
                let capable = peers.filter {
                    $0.isOnline && $0.runtimeSupported(assignedRuntime)
                    && $0.runtimeSetupReady(assignedRuntime) && $0.providerMatch
                }
                if capable.count == 1 {
                    return .peer(peerId: capable[0].peerId)
                }
                if capable.count > 1 {
                    return .requiresDeviceSelection(peerIds: capable.map(\.peerId))
                }
                if localCanRun { return .localOnly }
                return .noEligible(reason: .noEligibleDevice)
            }
        }

        // Non-host-specific routing follows normal device-target logic.
        switch deviceTarget.kind {
        case .local:
            if localCanRun { return .localOnly }
            return .noEligible(reason: .noEligibleDevice)

        case .peer:
            if let peerId = deviceTarget.targetPeerId,
               let peer = peers.first(where: { $0.peerId == peerId }),
               peer.isOnline, peer.providerMatch,
               peer.runtimeSupported(assignedRuntime),
               peer.runtimeAvailableSlots(assignedRuntime) > 0 {
                return .peer(peerId: peerId)
            }
            return .noEligible(reason: .noEligibleDevice)

        case .remoteFirst:
            if let best = bestRuntimePeer(
                runtime: assignedRuntime, peers: peers
            ) {
                return .peer(peerId: best.peerId)
            }
            if localCanRun { return .localOnly }
            return .noEligible(reason: .noEligibleDevice)

        case .automatic:
            if localCanRun { return .localOnly }
            if let best = bestRuntimePeer(
                runtime: assignedRuntime, peers: peers
            ) {
                return .peer(peerId: best.peerId)
            }
            return .noEligible(reason: .noEligibleDevice)
        }
    }

    // MARK: - Peer selection

    private static func bestRuntimePeer(
        runtime: AgentRuntimeKind,
        peers: [any RuntimeRoutingPeerInfo]
    ) -> (any RuntimeRoutingPeerInfo)? {
        peers
            .filter {
                $0.isOnline && $0.providerMatch
                && $0.runtimeSupported(runtime)
                && $0.runtimeSetupReady(runtime)
                && $0.runtimeAvailableSlots(runtime) > 0
            }
            .max { $0.runtimeAvailableSlots(runtime) < $1.runtimeAvailableSlots(runtime) }
    }

    // MARK: - Validation

    /// Returns an error when an explicit runtime target is incompatible with
    /// the classified requirement (e.g. `.fast` target but task needs GUI).
    static func validateExplicitTarget(
        _ target: TaskRuntimeTarget,
        requirement: TaskRuntimeRequirement
    ) -> RuntimeClassificationError? {
        switch target {
        case .fast:
            if requirement.requiredCapabilities.desktopObservation
                || requirement.requiredCapabilities.desktopInput {
                return .fastIncompatible(
                    "Task requires GUI capabilities not available in Fast Worker."
                )
            }
        case .app, .isolatedVM, .automatic:
            break
        }
        return nil
    }
}
