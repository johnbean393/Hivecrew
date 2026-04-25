import Foundation
import HivecrewLLM

public struct TaskCreationRequest: Sendable {
    public let taskId: String?
    public let description: String
    public let providerId: String
    public let modelId: String
    public let executionTarget: TaskExecutionTarget
    public let runtimeTarget: TaskRuntimeTarget
    public let reasoningEnabled: Bool?
    public let reasoningEffort: String?
    public let serviceTier: LLMServiceTier?
    public let attachedFilePaths: [String]
    public let attachmentInfos: [AttachmentInfo]?
    public let outputDirectory: String?
    public let mentionedSkillNames: [String]
    public let referencedTaskIds: [String]
    public let continuationSourceTaskId: String?
    public let retrievalContextPackId: String?
    public let retrievalInlineContextBlocks: [String]
    public let retrievalContextAttachmentPaths: [String]
    public let retrievalSelectedSuggestionIds: [String]
    public let retrievalModeOverrides: [String: String]
    public let clusterReferenceContextBlocks: [String]
    public let clusterReferenceFiles: [ClusterReferenceFile]
    public let planFirstEnabled: Bool
    public let planMarkdown: String?
    public let planSelectedSkillNames: [String]?
    public let localAccessGrants: [LocalAccessGrant]
    public let clusterOwnerTaskId: String?
    public let clusterExecutionAttempt: Int
    public let clusterLeaseId: String?

    public init(
        taskId: String? = nil,
        description: String,
        providerId: String,
        modelId: String,
        executionTarget: TaskExecutionTarget = .automatic,
        runtimeTarget: TaskRuntimeTarget = .automatic,
        reasoningEnabled: Bool? = nil,
        reasoningEffort: String? = nil,
        serviceTier: LLMServiceTier? = nil,
        attachedFilePaths: [String] = [],
        attachmentInfos: [AttachmentInfo]? = nil,
        outputDirectory: String? = nil,
        mentionedSkillNames: [String] = [],
        referencedTaskIds: [String] = [],
        continuationSourceTaskId: String? = nil,
        retrievalContextPackId: String? = nil,
        retrievalInlineContextBlocks: [String] = [],
        retrievalContextAttachmentPaths: [String] = [],
        retrievalSelectedSuggestionIds: [String] = [],
        retrievalModeOverrides: [String: String] = [:],
        clusterReferenceContextBlocks: [String] = [],
        clusterReferenceFiles: [ClusterReferenceFile] = [],
        planFirstEnabled: Bool = false,
        planMarkdown: String? = nil,
        planSelectedSkillNames: [String]? = nil,
        localAccessGrants: [LocalAccessGrant] = [],
        clusterOwnerTaskId: String? = nil,
        clusterExecutionAttempt: Int = 0,
        clusterLeaseId: String? = nil
    ) {
        self.taskId = taskId
        self.description = description
        self.providerId = providerId
        self.modelId = modelId
        self.executionTarget = executionTarget
        self.runtimeTarget = runtimeTarget
        self.reasoningEnabled = reasoningEnabled
        self.reasoningEffort = reasoningEffort
        self.serviceTier = serviceTier
        self.attachedFilePaths = attachedFilePaths
        self.attachmentInfos = attachmentInfos
        self.outputDirectory = outputDirectory
        self.mentionedSkillNames = mentionedSkillNames
        self.referencedTaskIds = referencedTaskIds
        self.continuationSourceTaskId = continuationSourceTaskId
        self.retrievalContextPackId = retrievalContextPackId
        self.retrievalInlineContextBlocks = retrievalInlineContextBlocks
        self.retrievalContextAttachmentPaths = retrievalContextAttachmentPaths
        self.retrievalSelectedSuggestionIds = retrievalSelectedSuggestionIds
        self.retrievalModeOverrides = retrievalModeOverrides
        self.clusterReferenceContextBlocks = clusterReferenceContextBlocks
        self.clusterReferenceFiles = clusterReferenceFiles
        self.planFirstEnabled = planFirstEnabled
        self.planMarkdown = planMarkdown
        self.planSelectedSkillNames = planSelectedSkillNames
        self.localAccessGrants = localAccessGrants
        self.clusterOwnerTaskId = clusterOwnerTaskId
        self.clusterExecutionAttempt = clusterExecutionAttempt
        self.clusterLeaseId = clusterLeaseId
    }
}
