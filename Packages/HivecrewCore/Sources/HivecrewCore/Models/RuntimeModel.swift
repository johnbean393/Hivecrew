//
//  RuntimeModel.swift
//  HivecrewCore
//
//  Runtime-neutral execution types for multi-runtime task routing.
//

import Foundation

// MARK: - Runtime Kind

public enum AgentRuntimeKind: Int, Codable, Sendable, Hashable {
    case fast = 0
    case app = 1
    case isolatedVM = 2

    public var displayName: String {
        switch self {
        case .fast: return "Fast Worker"
        case .app: return "App Worker"
        case .isolatedVM: return "Isolated VM"
        }
    }
}

// MARK: - Runtime Capabilities

public struct RuntimeCapabilities: Codable, Sendable, Equatable {
    public var shell: Bool
    public var filesystem: Bool
    public var network: Bool
    public var desktopObservation: Bool
    public var desktopInput: Bool
    public var hostAppAccess: Bool
    public var isolatedOS: Bool

    public init(
        shell: Bool = false,
        filesystem: Bool = false,
        network: Bool = false,
        desktopObservation: Bool = false,
        desktopInput: Bool = false,
        hostAppAccess: Bool = false,
        isolatedOS: Bool = false
    ) {
        self.shell = shell
        self.filesystem = filesystem
        self.network = network
        self.desktopObservation = desktopObservation
        self.desktopInput = desktopInput
        self.hostAppAccess = hostAppAccess
        self.isolatedOS = isolatedOS
    }

    public static let fast = RuntimeCapabilities(
        shell: true,
        filesystem: true,
        network: true
    )

    public static let app = RuntimeCapabilities(
        shell: true,
        filesystem: true,
        network: true,
        desktopObservation: true,
        desktopInput: true,
        hostAppAccess: true
    )

    public static let vm = RuntimeCapabilities(
        shell: true,
        filesystem: true,
        network: true,
        desktopObservation: true,
        desktopInput: true,
        isolatedOS: true
    )
}

// MARK: - Task Runtime Target

public enum TaskRuntimeTarget: Int, Codable, Sendable {
    case automatic = 0
    case fast = 1
    case app = 2
    case isolatedVM = 3

    public var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .fast: return "Fast Worker"
        case .app: return "App Worker"
        case .isolatedVM: return "Isolated VM"
        }
    }
}

// MARK: - Task Risk Level

public enum TaskRiskLevel: Int, Codable, Sendable {
    case low = 0
    case trustedGUI = 1
    case untrusted = 2
    case destructive = 3
}

// MARK: - Runtime Setup Requirement

public enum RuntimeSetupRequirement: String, Codable, Sendable {
    case appPermissionsMissing
    case cuaDriverMissing
    case vmTemplateMissing
    case providerUnavailable
    case noEligibleDevice
}

// MARK: - Task Runtime Requirement

public struct TaskRuntimeRequirement: Codable, Sendable {
    public var preferredRuntime: AgentRuntimeKind
    public var allowedRuntimes: Set<AgentRuntimeKind>
    public var requiredCapabilities: RuntimeCapabilities
    public var requiresHostSpecificState: Bool
    public var requiresSpecificDevice: Bool
    public var riskLevel: TaskRiskLevel
    public var setupRequirement: RuntimeSetupRequirement?

    public init(
        preferredRuntime: AgentRuntimeKind,
        allowedRuntimes: Set<AgentRuntimeKind>,
        requiredCapabilities: RuntimeCapabilities,
        requiresHostSpecificState: Bool = false,
        requiresSpecificDevice: Bool = false,
        riskLevel: TaskRiskLevel = .low,
        setupRequirement: RuntimeSetupRequirement? = nil
    ) {
        self.preferredRuntime = preferredRuntime
        self.allowedRuntimes = allowedRuntimes
        self.requiredCapabilities = requiredCapabilities
        self.requiresHostSpecificState = requiresHostSpecificState
        self.requiresSpecificDevice = requiresSpecificDevice
        self.riskLevel = riskLevel
        self.setupRequirement = setupRequirement
    }
}

// MARK: - Runtime Migration Event

public struct RuntimeMigrationEvent: Codable, Sendable, Identifiable {
    public var id: UUID
    public var taskId: String
    public var sessionId: String?
    public var sourceRuntime: AgentRuntimeKind
    public var destinationRuntime: AgentRuntimeKind
    public var reason: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        taskId: String,
        sessionId: String? = nil,
        sourceRuntime: AgentRuntimeKind,
        destinationRuntime: AgentRuntimeKind,
        reason: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.taskId = taskId
        self.sessionId = sessionId
        self.sourceRuntime = sourceRuntime
        self.destinationRuntime = destinationRuntime
        self.reason = reason
        self.createdAt = createdAt
    }
}

// MARK: - Task Setup Requirement

public struct TaskSetupRequirement: Codable, Sendable {
    public var runtimeKind: AgentRuntimeKind
    public var reason: RuntimeSetupRequirement
    public var deviceId: String?
    public var userFacingMessage: String

    public init(
        runtimeKind: AgentRuntimeKind,
        reason: RuntimeSetupRequirement,
        deviceId: String? = nil,
        userFacingMessage: String
    ) {
        self.runtimeKind = runtimeKind
        self.reason = reason
        self.deviceId = deviceId
        self.userFacingMessage = userFacingMessage
    }
}
