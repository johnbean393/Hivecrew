import Testing
import Foundation
@testable import HivecrewCore

// MARK: - AgentRuntimeKind

@Test func agentRuntimeKindCodableRoundTrip() throws {
    for kind in [AgentRuntimeKind.fast, .app, .isolatedVM] {
        let data = try JSONEncoder().encode(kind)
        let decoded = try JSONDecoder().decode(AgentRuntimeKind.self, from: data)
        #expect(decoded == kind)
    }
}

@Test func agentRuntimeKindRawValues() {
    #expect(AgentRuntimeKind.fast.rawValue == 0)
    #expect(AgentRuntimeKind.app.rawValue == 1)
    #expect(AgentRuntimeKind.isolatedVM.rawValue == 2)
}

@Test func agentRuntimeKindDisplayName() {
    #expect(AgentRuntimeKind.fast.displayName == "Fast Worker")
    #expect(AgentRuntimeKind.app.displayName == "App Worker")
    #expect(AgentRuntimeKind.isolatedVM.displayName == "Isolated VM")
}

// MARK: - TaskRuntimeTarget

@Test func taskRuntimeTargetCodableRoundTrip() throws {
    for target in [TaskRuntimeTarget.automatic, .fast, .app, .isolatedVM] {
        let data = try JSONEncoder().encode(target)
        let decoded = try JSONDecoder().decode(TaskRuntimeTarget.self, from: data)
        #expect(decoded == target)
    }
}

@Test func taskRuntimeTargetDefaultsToAutomaticWhenMissing() throws {
    struct Wrapper: Codable {
        var runtimeTarget: TaskRuntimeTarget?
    }
    let json = "{}"
    let data = json.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(Wrapper.self, from: data)
    #expect(decoded.runtimeTarget == nil)

    let withValue = #"{"runtimeTarget":0}"#
    let decoded2 = try JSONDecoder().decode(Wrapper.self, from: withValue.data(using: .utf8)!)
    #expect(decoded2.runtimeTarget == .automatic)
}

// MARK: - RuntimeCapabilities

@Test func runtimeCapabilitiesCodableRoundTrip() throws {
    let caps = RuntimeCapabilities.vm
    let data = try JSONEncoder().encode(caps)
    let decoded = try JSONDecoder().decode(RuntimeCapabilities.self, from: data)
    #expect(decoded == caps)
}

@Test func runtimeCapabilitiesFactories() {
    let fast = RuntimeCapabilities.fast
    #expect(fast.shell == true)
    #expect(fast.filesystem == true)
    #expect(fast.network == true)
    #expect(fast.desktopObservation == false)
    #expect(fast.desktopInput == false)
    #expect(fast.hostAppAccess == false)
    #expect(fast.isolatedOS == false)

    let app = RuntimeCapabilities.app
    #expect(app.desktopObservation == true)
    #expect(app.desktopInput == true)
    #expect(app.hostAppAccess == true)
    #expect(app.isolatedOS == false)

    let vm = RuntimeCapabilities.vm
    #expect(vm.desktopObservation == true)
    #expect(vm.desktopInput == true)
    #expect(vm.hostAppAccess == false)
    #expect(vm.isolatedOS == true)
}

// MARK: - TaskRuntimeRequirement

@Test func taskRuntimeRequirementCodableRoundTrip() throws {
    let req = TaskRuntimeRequirement(
        preferredRuntime: .fast,
        allowedRuntimes: [.fast, .isolatedVM],
        requiredCapabilities: .fast,
        requiresHostSpecificState: false,
        requiresSpecificDevice: false,
        riskLevel: .low,
        setupRequirement: nil
    )
    let data = try JSONEncoder().encode(req)
    let decoded = try JSONDecoder().decode(TaskRuntimeRequirement.self, from: data)
    #expect(decoded.preferredRuntime == .fast)
    #expect(decoded.allowedRuntimes == [.fast, .isolatedVM])
    #expect(decoded.riskLevel == .low)
    #expect(decoded.setupRequirement == nil)
}

// MARK: - RuntimeMigrationEvent

@Test func runtimeMigrationEventCodableRoundTrip() throws {
    let event = RuntimeMigrationEvent(
        taskId: "task-1",
        sessionId: "session-1",
        sourceRuntime: .fast,
        destinationRuntime: .isolatedVM,
        reason: "GUI needed"
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let data = try encoder.encode(event)
    let decoded = try decoder.decode(RuntimeMigrationEvent.self, from: data)
    #expect(decoded.taskId == "task-1")
    #expect(decoded.sessionId == "session-1")
    #expect(decoded.sourceRuntime == .fast)
    #expect(decoded.destinationRuntime == .isolatedVM)
    #expect(decoded.reason == "GUI needed")
}

// MARK: - TaskSetupRequirement

@Test func taskSetupRequirementCodableRoundTrip() throws {
    let req = TaskSetupRequirement(
        runtimeKind: .app,
        reason: .appPermissionsMissing,
        deviceId: "device-42",
        userFacingMessage: "Grant Accessibility permission on your Mac"
    )
    let data = try JSONEncoder().encode(req)
    let decoded = try JSONDecoder().decode(TaskSetupRequirement.self, from: data)
    #expect(decoded.runtimeKind == .app)
    #expect(decoded.reason == .appPermissionsMissing)
    #expect(decoded.deviceId == "device-42")
    #expect(decoded.userFacingMessage.contains("Accessibility"))
}

// MARK: - TaskRiskLevel

@Test func taskRiskLevelOrdering() {
    #expect(TaskRiskLevel.low.rawValue < TaskRiskLevel.trustedGUI.rawValue)
    #expect(TaskRiskLevel.trustedGUI.rawValue < TaskRiskLevel.untrusted.rawValue)
    #expect(TaskRiskLevel.untrusted.rawValue < TaskRiskLevel.destructive.rawValue)
}

// MARK: - AgentRuntimeKind Set encoding

@Test func agentRuntimeKindSetCodableRoundTrip() throws {
    let set: Set<AgentRuntimeKind> = [.fast, .app, .isolatedVM]
    let data = try JSONEncoder().encode(set)
    let decoded = try JSONDecoder().decode(Set<AgentRuntimeKind>.self, from: data)
    #expect(decoded == set)
}
