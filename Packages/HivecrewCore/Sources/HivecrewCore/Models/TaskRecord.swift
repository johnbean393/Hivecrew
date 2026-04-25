//
//  TaskRecord.swift
//  Hivecrew
//
//  SwiftData model for persisting task records
//

import Foundation
import HivecrewLLM
import SwiftData

/// Status of a task in the queue/execution lifecycle
public enum TaskStatus: Int, Codable, CaseIterable {
    case queued = 0        // Task is queued, waiting to start
    case waitingForVM = 1  // Yellow dot - waiting for VM to become available
    case running = 2       // Green dot - agent is actively working
    case completed = 3     // Task completed successfully
    case failed = 4        // Red dot - task failed
    case cancelled = 5     // Task was cancelled by user
    case paused = 6        // Yellow dot - agent is paused, awaiting user
    case timedOut = 7      // Orange dot - task exceeded time limit
    case maxIterations = 8 // Orange dot - task exceeded max iterations
    case planning = 9      // Yellow dot - plan is being generated
    case planReview = 10   // Blue dot - awaiting user review/edit of plan
    case planFailed = 11   // Red dot - planning failed
    case writebackReview = 12 // Blue dot - awaiting user review/apply for staged local changes
    
    public var displayName: String {
        switch self {
        case .queued: return String(localized: "Queued")
        case .waitingForVM: return String(localized: "Awaiting VM")
        case .running: return String(localized: "In Progress")
        case .completed: return String(localized: "Completed")
        case .failed: return String(localized: "Failed")
        case .cancelled: return String(localized: "Cancelled")
        case .paused: return String(localized: "Paused")
        case .timedOut: return String(localized: "Timed Out")
        case .maxIterations: return String(localized: "Max Iterations")
        case .planning: return String(localized: "Generating Plan")
        case .planReview: return String(localized: "Review Plan")
        case .planFailed: return String(localized: "Planning Failed")
        case .writebackReview: return String(localized: "Review Changes")
        }
    }
    
    public var statusColor: String {
        switch self {
        case .queued, .waitingForVM, .paused, .planning: return "yellow"
        case .running: return "green"
        case .completed: return "gray"
        case .failed, .planFailed: return "red"
        case .cancelled: return "gray"
        case .timedOut, .maxIterations: return "orange"
        case .planReview: return "blue"
        case .writebackReview: return "blue"
        }
    }
    
    public var isActive: Bool {
        switch self {
        case .queued, .waitingForVM, .running, .paused, .planning, .planReview:
            return true
        case .completed, .failed, .cancelled, .timedOut, .maxIterations, .planFailed, .writebackReview:
            return false
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .timedOut, .maxIterations, .planFailed:
            return true
        case .queued, .waitingForVM, .running, .paused, .planning, .planReview, .writebackReview:
            return false
        }
    }
}

public enum ClusterExecutionState: Int, Codable, CaseIterable {
    case none = 0
    case dispatchingRemote = 1
    case runningRemote = 2
    case recoveringRemote = 3
}

public enum RemoteLeaseState: Int, Codable, CaseIterable {
    case none = 0
    case dispatching = 1
    case running = 2
    case suspect = 3
    case recovering = 4
    case completedAwaitingImport = 5
    case superseded = 6
}

public struct ClusterReferenceFile: Codable, Hashable, Sendable {
    public let relativePath: String
    public let stagedPath: String

    public init(relativePath: String, stagedPath: String) {
        self.relativePath = relativePath
        self.stagedPath = stagedPath
    }
}

/// SwiftData model for persisting task records
@Model
public final class TaskRecord {
    public static let remoteOnlyProviderPrefix = "cluster-remote:"
    
    /// Unique identifier for this task
    @Attribute(.unique) public var id: String
    
    /// LLM-generated short title (e.g., "Create Paris Trip Research `docx`")
    public var title: String
    
    /// Full user-provided task description
    public var taskDescription: String
    
    /// Current status of the task
    public var statusRaw: Int
    
    /// When the task was created
    public var createdAt: Date

    /// Sort order for UI display (lower = higher in the list)
    public var sortOrder: Int = Int.max
    
    /// When the task started running
    public var startedAt: Date?
    
    /// When the task completed (success, failure, or cancellation)
    public var completedAt: Date?
    
    /// ID of the VM assigned to this task (nil if not yet assigned)
    public var assignedVMId: String?
    
    /// ID of the agent session running this task
    public var sessionId: String?
    
    /// ID of the LLM provider to use
    public var providerId: String
    
    /// Model ID to use (e.g., "moonshotai/kimi-k2.5", "claude-3-opus")
    public var modelId: String

    /// Optional reasoning toggle persisted for models with boolean reasoning support.
    public var reasoningEnabled: Bool?

    /// Optional reasoning effort persisted for models with explicit effort support.
    public var reasoningEffort: String?

    /// Optional service tier persisted for providers that expose serving tiers.
    public var serviceTier: LLMServiceTier?
    
    /// Summary of the task result (on completion)
    public var resultSummary: String?
    
    /// Error message (on failure)
    public var errorMessage: String?
    
    /// Legacy: Paths to files attached to this task (copied to VM's shared folder)
    /// Kept for backwards compatibility with older database versions
    /// New tasks should use attachmentInfos instead
    private var legacyAttachedFilePaths: [String]?
    
    /// JSON-encoded attachment info for files attached to this task
    /// Stores both original and copied paths for each attachment
    private var attachmentInfosData: Data?
    
    /// Paths to output files produced by this task (copied from VM's outbox)
    /// Optional to support migration from older database versions
    public var outputFilePaths: [String]?
    
    /// Custom output directory for this task (overrides app-level setting)
    /// If nil, uses the app's default output directory setting
    public var outputDirectory: String?
    
    /// Names of skills explicitly mentioned by the user via @skill-name
    /// These skills will be force-included in addition to auto-matched skills
    public var mentionedSkillNames: [String]?

    /// Direct task references selected by the user for continuation context.
    public var referencedTaskIds: [String]?

    /// The primary source task when a continuation was initiated from a task action.
    public var continuationSourceTaskId: String?

    /// Approved retrieval context pack ID used for this task (if any).
    public var retrievalContextPackId: String?

    /// Additional file paths materialized by retrieval context packing.
    public var retrievalContextAttachmentPaths: [String]?

    /// Suggestion IDs selected by the user during context approval.
    public var retrievalSelectedSuggestionIds: [String]?

    /// JSON-encoded inline context blocks to inject into the system prompt.
    private var retrievalInlineContextData: Data?

    /// JSON-encoded per-suggestion mode overrides at pack creation time.
    private var retrievalModeOverridesData: Data?

    /// Owner-materialized continuation context blocks staged for a remote worker.
    private var clusterReferenceContextBlocksData: Data?

    /// Owner-materialized reference bundle files staged for a remote worker.
    private var clusterReferenceFilesData: Data?
    
    /// Whether the task was verified as successful by the completion check
    /// nil = not yet checked, true = verified success, false = verified failure
    public var wasSuccessful: Bool?
    
    // MARK: - Cluster Execution Properties
    
    /// Legacy persisted backing field for the owner task ID of an executor-side lease record.
    /// Nil for normal local tasks and owner-side canonical task records.
    private var clusterCoordinatorTaskId: String?

    /// Canonical owner task ID for executor-side lease records.
    public var clusterOwnerTaskId: String? {
        get { clusterCoordinatorTaskId }
        set { clusterCoordinatorTaskId = newValue }
    }

    /// Owning node tunnel ID for executor-side cluster execution records.
    /// Nil for locally-owned tasks.
    public var clusterOwnerNodeId: String?

    /// Human-readable owner device name for executor-side display.
    public var clusterOwnerNodeName: String?

    /// User-selected execution target for the canonical owner-side task.
    private var executionTargetKindRaw: Int = TaskExecutionTargetKind.automatic.rawValue

    /// Target peer tunnel ID when the task is pinned to a specific peer.
    public var executionTargetPeerId: String?

    /// Cached peer display name when the task is pinned to a specific peer.
    public var executionTargetPeerName: String?
    
    /// Remote executor task ID currently leased by the owner.
    public var clusterWorkerTaskId: String?
    
    /// Peer tunnel ID currently executing this owner-owned task.
    public var clusterPeerId: String?
    
    /// Human-readable peer name for UI display while remotely executing.
    public var clusterPeerName: String?
    
    /// Monotonic attempt/generation number for owner-managed remote execution.
    public var clusterExecutionAttempt: Int = 0

    /// Owner-generated stable lease identifier for the current remote attempt.
    public var clusterLeaseId: String?

    /// Time the owner last heard from the remote worker for this lease.
    public var clusterLastRemoteContactAt: Date?

    /// Time the current lease first started failing owner reconciliation.
    public var clusterLeaseFirstFailureAt: Date?

    /// Consecutive reconciliation failures for the current lease.
    public var clusterLeaseFailureCount: Int = 0

    /// Directories containing quarantined artifacts for superseded remote attempts.
    public var clusterSupersededArtifactDirectories: [String]?

    private var remoteLeaseStateRaw: Int = RemoteLeaseState.none.rawValue

    public var remoteLeaseState: RemoteLeaseState {
        get { RemoteLeaseState(rawValue: remoteLeaseStateRaw) ?? .none }
        set { remoteLeaseStateRaw = newValue.rawValue }
    }
    
    private var clusterExecutionStateRaw: Int = ClusterExecutionState.none.rawValue
    
    public var clusterExecutionState: ClusterExecutionState {
        get { ClusterExecutionState(rawValue: clusterExecutionStateRaw) ?? .none }
        set { clusterExecutionStateRaw = newValue.rawValue }
    }

    public var executionTarget: TaskExecutionTarget {
        get {
            TaskExecutionTarget(
                kind: TaskExecutionTargetKind(rawValue: executionTargetKindRaw) ?? .automatic,
                peerId: executionTargetPeerId,
                peerName: executionTargetPeerName
            )
        }
        set {
            executionTargetKindRaw = newValue.kind.rawValue
            executionTargetPeerId = newValue.peerId
            executionTargetPeerName = newValue.peerName
        }
    }
    
    // MARK: - Runtime Targeting Properties

    /// Requested runtime target (user/API-specified).
    /// Optional for migration compatibility — nil means `.automatic`.
    private var runtimeTargetRaw: Int?

    public var runtimeTarget: TaskRuntimeTarget {
        get { runtimeTargetRaw.flatMap { TaskRuntimeTarget(rawValue: $0) } ?? .automatic }
        set { runtimeTargetRaw = newValue.rawValue }
    }

    /// Assigned runtime kind after routing (nil until task starts).
    private var assignedRuntimeKindRaw: Int?

    public var assignedRuntimeKind: AgentRuntimeKind? {
        get { assignedRuntimeKindRaw.flatMap { AgentRuntimeKind(rawValue: $0) } }
        set { assignedRuntimeKindRaw = newValue?.rawValue }
    }

    /// JSON-encoded runtime migration events for this task.
    private var runtimeMigrationEventsData: Data?

    public var runtimeMigrationEvents: [RuntimeMigrationEvent] {
        get {
            guard let d = runtimeMigrationEventsData,
                  let decoded = try? JSONDecoder().decode([RuntimeMigrationEvent].self, from: d)
            else { return [] }
            return decoded
        }
        set { runtimeMigrationEventsData = try? JSONEncoder().encode(newValue) }
    }

    /// JSON-encoded setup requirement if the task cannot proceed without setup.
    private var setupRequirementData: Data?

    public var setupRequirement: TaskSetupRequirement? {
        get {
            guard let d = setupRequirementData,
                  let decoded = try? JSONDecoder().decode(TaskSetupRequirement.self, from: d)
            else { return nil }
            return decoded
        }
        set { setupRequirementData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    // MARK: - Plan Mode Properties
    
    /// Whether plan mode was enabled for this task (optional for migration compatibility)
    private var planFirstEnabledRaw: Bool?
    
    /// The generated/edited execution plan (Markdown with checkboxes)
    public var planMarkdown: String?
    
    /// Names of skills auto-selected during planning
    public var planSelectedSkillNames: [String]?

    /// JSON-encoded local destination grants available for staged writeback.
    private var localAccessGrantsData: Data?

    /// JSON-encoded pending staged writeback operations for this task.
    private var pendingWritebackOperationsData: Data?

    /// Local paths that were updated by an approved writeback batch.
    public var appliedWritebackPaths: [String]?
    
    /// Computed property for planFirstEnabled with default value
    public var planFirstEnabled: Bool {
        get { planFirstEnabledRaw ?? false }
        set { planFirstEnabledRaw = newValue }
    }

    // MARK: - Retrieval Context Properties

    public var retrievalInlineContextBlocks: [String] {
        get {
            guard
                let retrievalInlineContextData,
                let decoded = try? JSONDecoder().decode([String].self, from: retrievalInlineContextData)
            else {
                return []
            }
            return decoded
        }
        set {
            retrievalInlineContextData = try? JSONEncoder().encode(newValue)
        }
    }

    public var retrievalModeOverrides: [String: String] {
        get {
            guard
                let retrievalModeOverridesData,
                let decoded = try? JSONDecoder().decode([String: String].self, from: retrievalModeOverridesData)
            else {
                return [:]
            }
            return decoded
        }
        set {
            retrievalModeOverridesData = try? JSONEncoder().encode(newValue)
        }
    }

    public var clusterReferenceContextBlocks: [String] {
        get {
            guard
                let clusterReferenceContextBlocksData,
                let decoded = try? JSONDecoder().decode([String].self, from: clusterReferenceContextBlocksData)
            else {
                return []
            }
            return decoded
        }
        set {
            clusterReferenceContextBlocksData = try? JSONEncoder().encode(newValue)
        }
    }

    public var clusterReferenceFiles: [ClusterReferenceFile] {
        get {
            guard
                let clusterReferenceFilesData,
                let decoded = try? JSONDecoder().decode([ClusterReferenceFile].self, from: clusterReferenceFilesData)
            else {
                return []
            }
            return decoded
        }
        set {
            clusterReferenceFilesData = try? JSONEncoder().encode(newValue)
        }
    }

    // MARK: - Writeback Properties

    public var localAccessGrants: [LocalAccessGrant] {
        get {
            guard
                let localAccessGrantsData,
                let decoded = try? JSONDecoder().decode([LocalAccessGrant].self, from: localAccessGrantsData)
            else {
                return []
            }
            return decoded
        }
        set {
            localAccessGrantsData = try? JSONEncoder().encode(newValue)
        }
    }

    public var pendingWritebackOperations: [PendingWritebackOperation] {
        get {
            guard
                let pendingWritebackOperationsData,
                let decoded = try? JSONDecoder().decode([PendingWritebackOperation].self, from: pendingWritebackOperationsData)
            else {
                return []
            }
            return decoded
        }
        set {
            pendingWritebackOperationsData = try? JSONEncoder().encode(newValue)
        }
    }

    public var hasPendingWriteback: Bool {
        !pendingWritebackOperations.isEmpty
    }
    
    // MARK: - Attachment Properties
    
    /// Decoded attachment infos from stored data
    /// Includes backwards compatibility: migrates legacy paths if needed
    public var attachmentInfos: [AttachmentInfo] {
        get {
            // First try to decode from new format
            if let data = attachmentInfosData,
               let infos = try? JSONDecoder().decode([AttachmentInfo].self, from: data) {
                return infos
            }
            // Fallback: migrate from legacy paths
            if let legacyPaths = legacyAttachedFilePaths {
                return legacyPaths.map { AttachmentInfo(path: $0) }
            }
            return []
        }
        set {
            attachmentInfosData = try? JSONEncoder().encode(newValue)
            // Clear legacy data once we have new format
            legacyAttachedFilePaths = nil
        }
    }
    
    /// Paths to files attached to this task
    /// Computed from attachmentInfos for backwards compatibility
    /// Returns effective paths (copied if available, original otherwise)
    public var attachedFilePaths: [String] {
        get {
            attachmentInfos.map { $0.effectivePath }
        }
        set {
            // When setting paths directly (legacy behavior), create basic AttachmentInfos
            attachmentInfos = newValue.map { AttachmentInfo(path: $0) }
        }
    }
    
    public init(
        id: String = UUID().uuidString,
        title: String,
        taskDescription: String,
        status: TaskStatus = .queued,
        createdAt: Date = Date(),
        sortOrder: Int = Int.max,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        assignedVMId: String? = nil,
        sessionId: String? = nil,
        providerId: String,
        modelId: String,
        executionTarget: TaskExecutionTarget = .automatic,
        runtimeTarget: TaskRuntimeTarget = .automatic,
        reasoningEnabled: Bool? = nil,
        reasoningEffort: String? = nil,
        serviceTier: LLMServiceTier? = nil,
        resultSummary: String? = nil,
        errorMessage: String? = nil,
        attachedFilePaths: [String] = [],
        attachmentInfos: [AttachmentInfo]? = nil,
        outputFilePaths: [String]? = nil,
        outputDirectory: String? = nil,
        mentionedSkillNames: [String]? = nil,
        referencedTaskIds: [String]? = nil,
        continuationSourceTaskId: String? = nil,
        retrievalContextPackId: String? = nil,
        retrievalInlineContextBlocks: [String] = [],
        retrievalContextAttachmentPaths: [String]? = nil,
        retrievalSelectedSuggestionIds: [String]? = nil,
        retrievalModeOverrides: [String: String]? = nil,
        clusterReferenceContextBlocks: [String] = [],
        clusterReferenceFiles: [ClusterReferenceFile] = [],
        planFirstEnabled: Bool = false,
        planMarkdown: String? = nil,
        planSelectedSkillNames: [String]? = nil,
        localAccessGrants: [LocalAccessGrant] = [],
        pendingWritebackOperations: [PendingWritebackOperation] = [],
        appliedWritebackPaths: [String]? = nil,
        clusterOwnerTaskId: String? = nil,
        clusterOwnerNodeId: String? = nil,
        clusterWorkerTaskId: String? = nil,
        clusterPeerId: String? = nil,
        clusterPeerName: String? = nil,
        clusterExecutionAttempt: Int = 0,
        clusterExecutionState: ClusterExecutionState = .none,
        clusterLeaseId: String? = nil,
        clusterLastRemoteContactAt: Date? = nil,
        clusterLeaseFirstFailureAt: Date? = nil,
        clusterLeaseFailureCount: Int = 0,
        clusterSupersededArtifactDirectories: [String]? = nil,
        remoteLeaseState: RemoteLeaseState = .none
    ) {
        self.id = id
        self.title = title
        self.taskDescription = taskDescription
        self.statusRaw = status.rawValue
        self.createdAt = createdAt
        self.sortOrder = sortOrder
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.assignedVMId = assignedVMId
        self.sessionId = sessionId
        self.providerId = providerId
        self.modelId = modelId
        self.reasoningEnabled = reasoningEnabled
        self.reasoningEffort = reasoningEffort
        self.serviceTier = serviceTier
        self.resultSummary = resultSummary
        self.errorMessage = errorMessage
        self.outputFilePaths = outputFilePaths
        self.outputDirectory = outputDirectory
        self.mentionedSkillNames = mentionedSkillNames
        self.referencedTaskIds = referencedTaskIds
        self.continuationSourceTaskId = continuationSourceTaskId
        self.retrievalContextPackId = retrievalContextPackId
        self.retrievalContextAttachmentPaths = retrievalContextAttachmentPaths
        self.retrievalSelectedSuggestionIds = retrievalSelectedSuggestionIds
        self.retrievalInlineContextData = try? JSONEncoder().encode(retrievalInlineContextBlocks)
        self.retrievalModeOverridesData = try? JSONEncoder().encode(retrievalModeOverrides ?? [:])
        self.clusterReferenceContextBlocksData = try? JSONEncoder().encode(clusterReferenceContextBlocks)
        self.clusterReferenceFilesData = try? JSONEncoder().encode(clusterReferenceFiles)
        self.planFirstEnabledRaw = planFirstEnabled
        self.planMarkdown = planMarkdown
        self.planSelectedSkillNames = planSelectedSkillNames
        self.localAccessGrantsData = try? JSONEncoder().encode(localAccessGrants)
        self.pendingWritebackOperationsData = try? JSONEncoder().encode(pendingWritebackOperations)
        self.appliedWritebackPaths = appliedWritebackPaths
        self.executionTargetKindRaw = executionTarget.kind.rawValue
        self.executionTargetPeerId = executionTarget.peerId
        self.executionTargetPeerName = executionTarget.peerName
        self.runtimeTargetRaw = runtimeTarget.rawValue
        self.clusterCoordinatorTaskId = clusterOwnerTaskId
        self.clusterOwnerNodeId = clusterOwnerNodeId
        self.clusterWorkerTaskId = clusterWorkerTaskId
        self.clusterPeerId = clusterPeerId
        self.clusterPeerName = clusterPeerName
        self.clusterExecutionAttempt = clusterExecutionAttempt
        self.clusterExecutionStateRaw = clusterExecutionState.rawValue
        self.clusterLeaseId = clusterLeaseId
        self.clusterLastRemoteContactAt = clusterLastRemoteContactAt
        self.clusterLeaseFirstFailureAt = clusterLeaseFirstFailureAt
        self.clusterLeaseFailureCount = clusterLeaseFailureCount
        self.clusterSupersededArtifactDirectories = clusterSupersededArtifactDirectories
        self.remoteLeaseStateRaw = remoteLeaseState.rawValue
        
        // Use new attachment infos if provided, otherwise fall back to legacy paths
        if let infos = attachmentInfos {
            self.attachmentInfosData = try? JSONEncoder().encode(infos)
            self.legacyAttachedFilePaths = nil
        } else if !attachedFilePaths.isEmpty {
            // Store as legacy paths for backwards compatibility
            self.legacyAttachedFilePaths = attachedFilePaths
            self.attachmentInfosData = nil
        } else {
            self.legacyAttachedFilePaths = nil
            self.attachmentInfosData = nil
        }
    }
    
    /// Computed status property
    public var status: TaskStatus {
        get { TaskStatus(rawValue: statusRaw) ?? .queued }
        set { statusRaw = newValue.rawValue }
    }
    
    /// Duration from creation to completion (or now if still running)
    public var duration: TimeInterval {
        let endTime = completedAt ?? Date()
        return endTime.timeIntervalSince(startedAt ?? createdAt)
    }
    
    /// Formatted duration string
    public var durationString: String {
        let seconds = Int(duration)
        if seconds < 60 {
            return "\(seconds)s"
        } else if seconds < 3600 {
            return "\(seconds / 60)m \(seconds % 60)s"
        } else {
            let hours = seconds / 3600
            let minutes = (seconds % 3600) / 60
            return "\(hours)h \(minutes)m"
        }
    }
    
    public var requiresRemoteClusterExecution: Bool {
        providerId.hasPrefix(Self.remoteOnlyProviderPrefix)
    }

    public var hasRemoteLease: Bool {
        guard let clusterPeerId, !clusterPeerId.isEmpty,
              let clusterWorkerTaskId, !clusterWorkerTaskId.isEmpty else {
            return false
        }
        return true
    }
    
    public var isExecutingRemotely: Bool {
        guard hasRemoteLease else { return false }
        switch remoteLeaseState {
        case .dispatching, .running, .suspect, .recovering, .completedAwaitingImport:
            return true
        case .none, .superseded:
            break
        }
        switch clusterExecutionState {
        case .runningRemote, .dispatchingRemote, .recoveringRemote:
            return true
        case .none:
            return false
        }
    }

    public var isPinnedToLocalExecution: Bool {
        executionTarget.kind == .local
    }

    /// Task has data-local constraints (access grants, pending writeback)
    /// that prevent remote dispatch.
    public var requiresLocalDevice: Bool {
        !localAccessGrants.isEmpty || hasPendingWriteback
            || !(appliedWritebackPaths ?? []).isEmpty
    }

    public var isPinnedToPeerExecution: Bool {
        executionTarget.kind == .peer && !isInternalClusterExecution
    }

    /// Internal executor-side record created for a remotely-owned task.
    /// These should stay out of normal task lists and dashboards.
    public var isInternalClusterExecution: Bool {
        clusterOwnerTaskId != nil
    }
    
    /// True if this task was (or is being) executed on a remote cluster node.
    public var wasExecutedRemotely: Bool {
        clusterPeerName != nil || clusterPeerId != nil
    }
    
    public var remoteNodeDisplayName: String? {
        guard isExecutingRemotely || wasExecutedRemotely else { return nil }
        return clusterPeerName
    }
}
