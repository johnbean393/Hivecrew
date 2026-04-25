//
//  RuntimeRoutingPolicyTests.swift
//  HivecrewTests
//
//  Tests for RuntimeRoutingPolicy pure-function routing decisions.
//

import Foundation
import Testing
import HivecrewCore
@testable import Hivecrew

// MARK: - Stub Peer

private struct StubPeer: RuntimeRoutingPeerInfo {
    var peerId: String
    var peerName: String?
    var isOnline: Bool = true
    var providerMatch: Bool = true
    private var supported: Set<AgentRuntimeKind> = [.fast, .app, .isolatedVM]
    private var slots: [AgentRuntimeKind: Int] = [.fast: 3, .app: 1, .isolatedVM: 2]
    private var ready: Set<AgentRuntimeKind> = [.fast, .app, .isolatedVM]

    init(
        id: String,
        name: String? = nil,
        online: Bool = true,
        providerMatch: Bool = true,
        supported: Set<AgentRuntimeKind> = [.fast, .app, .isolatedVM],
        slots: [AgentRuntimeKind: Int] = [.fast: 3, .app: 1, .isolatedVM: 2],
        ready: Set<AgentRuntimeKind> = [.fast, .app, .isolatedVM]
    ) {
        self.peerId = id
        self.peerName = name
        self.isOnline = online
        self.providerMatch = providerMatch
        self.supported = supported
        self.slots = slots
        self.ready = ready
    }

    func runtimeSupported(_ kind: AgentRuntimeKind) -> Bool { supported.contains(kind) }
    func runtimeAvailableSlots(_ kind: AgentRuntimeKind) -> Int { slots[kind] ?? 0 }
    func runtimeSetupReady(_ kind: AgentRuntimeKind) -> Bool { ready.contains(kind) }
}

// MARK: - Requirement helpers

private func fastRequirement() -> TaskRuntimeRequirement {
    TaskRuntimeRequirement(
        preferredRuntime: .fast,
        allowedRuntimes: [.fast],
        requiredCapabilities: .fast
    )
}

private func appRequirement(hostSpecific: Bool = false) -> TaskRuntimeRequirement {
    TaskRuntimeRequirement(
        preferredRuntime: .app,
        allowedRuntimes: [.app, .isolatedVM],
        requiredCapabilities: .app,
        requiresHostSpecificState: hostSpecific
    )
}

private func vmRequirement() -> TaskRuntimeRequirement {
    TaskRuntimeRequirement(
        preferredRuntime: .isolatedVM,
        allowedRuntimes: [.isolatedVM],
        requiredCapabilities: .vm
    )
}

// MARK: - Host-specific detection

@Test func hostSpecificPhraseDetection() {
    #expect(RuntimeRoutingPolicy.isHostSpecificRequest(description: "Open my Safari and check email"))
    #expect(RuntimeRoutingPolicy.isHostSpecificRequest(description: "Look at this Mac's Finder"))
    #expect(RuntimeRoutingPolicy.isHostSpecificRequest(description: "Use my logged.in session"))
    #expect(!RuntimeRoutingPolicy.isHostSpecificRequest(description: "Write a Python script to sort numbers"))
    #expect(!RuntimeRoutingPolicy.isHostSpecificRequest(description: "Search for flights to Paris"))
}

@Test func isHostSpecificCombinesFlags() {
    let req = appRequirement(hostSpecific: true)
    #expect(RuntimeRoutingPolicy.isHostSpecific(requirement: req, description: "anything"))

    let nonHost = fastRequirement()
    #expect(!RuntimeRoutingPolicy.isHostSpecific(requirement: nonHost, description: "just a regular task"))
}

@Test func hostAppAccessWithMatchingPhrase() {
    let req = TaskRuntimeRequirement(
        preferredRuntime: .app,
        allowedRuntimes: [.app],
        requiredCapabilities: .app
    )
    #expect(RuntimeRoutingPolicy.isHostSpecific(requirement: req, description: "open my Safari tabs"))
    #expect(!RuntimeRoutingPolicy.isHostSpecific(requirement: req, description: "open a web browser"))
}

// MARK: - Eligible device: local target

@Test func localTargetWithCapacity() {
    let result = RuntimeRoutingPolicy.eligibleDevice(
        deviceTarget: .local,
        assignedRuntime: .fast,
        requirement: fastRequirement(),
        description: "test",
        dataLocalConstraint: .none,
        localCanRun: true,
        isAppWorkerReady: false,
        peers: []
    )
    #expect(result == .localOnly)
}

@Test func localTargetNoCapacity() {
    let result = RuntimeRoutingPolicy.eligibleDevice(
        deviceTarget: .local,
        assignedRuntime: .fast,
        requirement: fastRequirement(),
        description: "test",
        dataLocalConstraint: .none,
        localCanRun: false,
        isAppWorkerReady: false,
        peers: []
    )
    #expect(result == .noEligible(reason: .noEligibleDevice))
}

// MARK: - Eligible device: automatic target

@Test func automaticTargetPrefersLocal() {
    let peer = StubPeer(id: "peer-1")
    let result = RuntimeRoutingPolicy.eligibleDevice(
        deviceTarget: .automatic,
        assignedRuntime: .fast,
        requirement: fastRequirement(),
        description: "test",
        dataLocalConstraint: .none,
        localCanRun: true,
        isAppWorkerReady: false,
        peers: [peer]
    )
    #expect(result == .localOnly)
}

@Test func automaticTargetFallsToPeer() {
    let peer = StubPeer(id: "peer-1")
    let result = RuntimeRoutingPolicy.eligibleDevice(
        deviceTarget: .automatic,
        assignedRuntime: .fast,
        requirement: fastRequirement(),
        description: "test",
        dataLocalConstraint: .none,
        localCanRun: false,
        isAppWorkerReady: false,
        peers: [peer]
    )
    #expect(result == .peer(peerId: "peer-1"))
}

// MARK: - Eligible device: remote-first target

@Test func remoteFirstPicksBestPeer() {
    let peer1 = StubPeer(id: "peer-1", slots: [.fast: 1, .app: 0, .isolatedVM: 0])
    let peer2 = StubPeer(id: "peer-2", slots: [.fast: 5, .app: 0, .isolatedVM: 0])
    let result = RuntimeRoutingPolicy.eligibleDevice(
        deviceTarget: .remoteFirst,
        assignedRuntime: .fast,
        requirement: fastRequirement(),
        description: "test",
        dataLocalConstraint: .none,
        localCanRun: true,
        isAppWorkerReady: false,
        peers: [peer1, peer2]
    )
    #expect(result == .peer(peerId: "peer-2"))
}

@Test func remoteFirstFallsBackToLocal() {
    let result = RuntimeRoutingPolicy.eligibleDevice(
        deviceTarget: .remoteFirst,
        assignedRuntime: .fast,
        requirement: fastRequirement(),
        description: "test",
        dataLocalConstraint: .none,
        localCanRun: true,
        isAppWorkerReady: false,
        peers: []
    )
    #expect(result == .localOnly)
}

// MARK: - Peer target

@Test func peerTargetWithSpecificPeer() {
    let peer = StubPeer(id: "peer-1")
    let result = RuntimeRoutingPolicy.eligibleDevice(
        deviceTarget: .peer(id: "peer-1", name: "Mac Mini"),
        assignedRuntime: .fast,
        requirement: fastRequirement(),
        description: "test",
        dataLocalConstraint: .none,
        localCanRun: true,
        isAppWorkerReady: false,
        peers: [peer]
    )
    #expect(result == .peer(peerId: "peer-1"))
}

@Test func peerTargetOfflinePeer() {
    let peer = StubPeer(id: "peer-1", online: false)
    let result = RuntimeRoutingPolicy.eligibleDevice(
        deviceTarget: .peer(id: "peer-1", name: "Mac Mini"),
        assignedRuntime: .fast,
        requirement: fastRequirement(),
        description: "test",
        dataLocalConstraint: .none,
        localCanRun: true,
        isAppWorkerReady: false,
        peers: [peer]
    )
    #expect(result == .noEligible(reason: .noEligibleDevice))
}

// MARK: - Host-specific routing

@Test func hostSpecificRemoteFirstOnePeerRoutes() {
    let peer = StubPeer(id: "peer-1")
    let result = RuntimeRoutingPolicy.eligibleDevice(
        deviceTarget: .remoteFirst,
        assignedRuntime: .app,
        requirement: appRequirement(hostSpecific: true),
        description: "open my Safari",
        dataLocalConstraint: .none,
        localCanRun: false,
        isAppWorkerReady: false,
        peers: [peer]
    )
    #expect(result == .peer(peerId: "peer-1"))
}

@Test func hostSpecificRemoteFirstMultiplePeersRequiresSelection() {
    let peer1 = StubPeer(id: "peer-1")
    let peer2 = StubPeer(id: "peer-2")
    let result = RuntimeRoutingPolicy.eligibleDevice(
        deviceTarget: .remoteFirst,
        assignedRuntime: .app,
        requirement: appRequirement(hostSpecific: true),
        description: "open my Safari",
        dataLocalConstraint: .none,
        localCanRun: false,
        isAppWorkerReady: false,
        peers: [peer1, peer2]
    )
    #expect(result == .requiresDeviceSelection(peerIds: ["peer-1", "peer-2"]))
}

@Test func hostSpecificLocalWithAppNotReady() {
    let result = RuntimeRoutingPolicy.eligibleDevice(
        deviceTarget: .automatic,
        assignedRuntime: .app,
        requirement: appRequirement(hostSpecific: true),
        description: "open my Safari",
        dataLocalConstraint: .none,
        localCanRun: false,
        isAppWorkerReady: false,
        peers: []
    )
    #expect(result == .noEligible(reason: .appPermissionsMissing))
}

// MARK: - Data-local pinning

@Test func dataLocalConstraintPinsToLocal() {
    let peer = StubPeer(id: "peer-1")
    let result = RuntimeRoutingPolicy.eligibleDevice(
        deviceTarget: .automatic,
        assignedRuntime: .fast,
        requirement: fastRequirement(),
        description: "test",
        dataLocalConstraint: .requiresLocalDevice,
        localCanRun: true,
        isAppWorkerReady: false,
        peers: [peer]
    )
    #expect(result == .localOnly)
}

@Test func dataLocalConstraintFailsWhenLocalCantRun() {
    let result = RuntimeRoutingPolicy.eligibleDevice(
        deviceTarget: .automatic,
        assignedRuntime: .fast,
        requirement: fastRequirement(),
        description: "test",
        dataLocalConstraint: .requiresLocalDevice,
        localCanRun: false,
        isAppWorkerReady: false,
        peers: []
    )
    #expect(result == .noEligible(reason: .noEligibleDevice))
}

// MARK: - Runtime filtering across peers

@Test func fastPeerWithNoVMSlotsAcceptsFast() {
    let peer = StubPeer(
        id: "peer-1",
        supported: [.fast],
        slots: [.fast: 3],
        ready: [.fast]
    )
    let result = RuntimeRoutingPolicy.eligibleDevice(
        deviceTarget: .remoteFirst,
        assignedRuntime: .fast,
        requirement: fastRequirement(),
        description: "test",
        dataLocalConstraint: .none,
        localCanRun: false,
        isAppWorkerReady: false,
        peers: [peer]
    )
    #expect(result == .peer(peerId: "peer-1"))
}

@Test func vmOnlyPeerRejectsApp() {
    let peer = StubPeer(
        id: "peer-1",
        supported: [.isolatedVM],
        slots: [.isolatedVM: 2],
        ready: [.isolatedVM]
    )
    let result = RuntimeRoutingPolicy.eligibleDevice(
        deviceTarget: .remoteFirst,
        assignedRuntime: .app,
        requirement: appRequirement(),
        description: "test",
        dataLocalConstraint: .none,
        localCanRun: false,
        isAppWorkerReady: false,
        peers: [peer]
    )
    #expect(result == .noEligible(reason: .noEligibleDevice))
}

@Test func appCapablePeerWithMissingPermissionsNotReady() {
    let peer = StubPeer(
        id: "peer-1",
        supported: [.fast, .app],
        slots: [.fast: 3, .app: 1],
        ready: [.fast]  // app NOT ready
    )
    let result = RuntimeRoutingPolicy.eligibleDevice(
        deviceTarget: .remoteFirst,
        assignedRuntime: .app,
        requirement: appRequirement(),
        description: "test",
        dataLocalConstraint: .none,
        localCanRun: false,
        isAppWorkerReady: false,
        peers: [peer]
    )
    #expect(result == .noEligible(reason: .noEligibleDevice))
}

// MARK: - Validation

@Test func validateFastTargetWithGUIRequirementFails() {
    let req = TaskRuntimeRequirement(
        preferredRuntime: .app,
        allowedRuntimes: [.app, .isolatedVM],
        requiredCapabilities: RuntimeCapabilities(
            shell: true, filesystem: true, network: true,
            desktopObservation: true, desktopInput: true
        )
    )
    let error = RuntimeRoutingPolicy.validateExplicitTarget(.fast, requirement: req)
    #expect(error != nil)
    if case .fastIncompatible = error {
        // expected
    } else {
        Issue.record("Expected fastIncompatible, got \(String(describing: error))")
    }
}

@Test func validateAppTargetAlwaysPasses() {
    let req = fastRequirement()
    let error = RuntimeRoutingPolicy.validateExplicitTarget(.app, requirement: req)
    #expect(error == nil)
}

@Test func validateAutomaticTargetAlwaysPasses() {
    let req = appRequirement()
    let error = RuntimeRoutingPolicy.validateExplicitTarget(.automatic, requirement: req)
    #expect(error == nil)
}
