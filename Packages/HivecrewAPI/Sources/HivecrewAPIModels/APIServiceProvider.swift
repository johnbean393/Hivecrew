//
//  APIServiceProvider.swift
//  HivecrewAPIModels
//
//  Service provider protocols (Foundation-only, used by both server and clients)
//

import Foundation

/// Abstraction layer between the API routes and the main application.
///
/// The host app supplies a concrete implementation of this protocol when
/// creating the ``HivecrewAPIServer``. All methods are `async throws` and
/// follow a consistent naming convention:
///
/// - **create…** / **get…** / **delete…** for CRUD operations.
/// - **perform…** for side-effect actions.
/// - **subscribe…** for streaming.
///
/// Methods that accept an `id` parameter always use the label `id`.
public protocol APIServiceProvider: Sendable {
    
    // MARK: - Task Operations
    
    func createTask(
        description: String,
        providerName: String,
        modelId: String,
        reasoningEnabled: Bool?,
        reasoningEffort: String?,
        attachedFilePaths: [String],
        outputDirectory: String?,
        planFirst: Bool,
        mentionedSkillNames: [String],
        referencedTaskIds: [String],
        continuationSourceTaskId: String?,
        contextPackId: String?,
        contextSuggestionIds: [String],
        contextModeOverrides: [String: String],
        contextInlineBlocks: [String],
        contextAttachmentPaths: [String]
    ) async throws -> APITask

    func createTaskBatch(
        description: String,
        targets: [CreateTaskBatchTarget],
        attachedFilePaths: [String],
        planFirst: Bool,
        mentionedSkillNames: [String]
    ) async throws -> [APITask]
    
    func getTasks(
        status: [APITaskStatus]?,
        limit: Int,
        offset: Int,
        sortBy: String,
        order: String
    ) async throws -> APITaskListResponse
    
    func getTask(id: String) async throws -> APITask
    
    func performTaskAction(id: String, action: APITaskAction, instructions: String?) async throws -> APITask
    
    func deleteTask(id: String) async throws
    
    func getTaskFiles(id: String) async throws -> APITaskFilesResponse
    
    func getTaskFileData(taskId: String, filename: String, isInput: Bool) async throws -> (data: Data, mimeType: String)

    func getTaskTraceBundle(id: String) async throws -> APITaskTraceBundleResponse

    func getTaskTraceFileData(taskId: String, relativePath: String) async throws -> (data: Data, mimeType: String)
    
    func getTaskScreenshot(id: String) async throws -> (data: Data, mimeType: String)?
    
    func getPendingQuestion(taskId: String) async throws -> APIAgentQuestion?
    
    func answerQuestion(taskId: String, questionId: String, answer: String) async throws
    
    func getPendingPermission(taskId: String) async throws -> APIPermissionRequest?
    
    func respondToPermission(taskId: String, permissionId: String, approved: Bool) async throws

    func getTaskWritebackReview(id: String) async throws -> APIWritebackReview?
    
    // MARK: - Schedule Operations
    
    func getScheduledTasks(limit: Int, offset: Int) async throws -> APIScheduledTaskListResponse
    
    func getScheduledTask(id: String) async throws -> APIScheduledTask
    
    func createScheduledTask(
        title: String,
        description: String,
        providerName: String,
        modelId: String,
        reasoningEnabled: Bool?,
        reasoningEffort: String?,
        attachedFilePaths: [String],
        outputDirectory: String?,
        schedule: APISchedule
    ) async throws -> APIScheduledTask
    
    func updateScheduledTask(id: String, request: UpdateScheduleRequest) async throws -> APIScheduledTask
    
    func deleteScheduledTask(id: String) async throws
    
    func runScheduledTaskNow(id: String) async throws -> APITask
    
    // MARK: - Provider Operations
    
    func getProviders() async throws -> APIProviderListResponse
    
    func getProvider(id: String) async throws -> APIProvider
    
    func getProviderByName(name: String) async throws -> APIProvider
    
    func getProviderModels(id: String) async throws -> APIModelListResponse

    func createProvider(request: APICreateProviderRequest) async throws -> APIProvider

    func updateProvider(id: String, request: APIUpdateProviderRequest) async throws -> APIProvider

    func deleteProvider(id: String) async throws

    func startProviderAuth(id: String) async throws -> APIProviderAuthStartResponse

    func getProviderAuthStatus(id: String) async throws -> APIProviderAuthStatusResponse

    func logoutProviderAuth(id: String) async throws -> APIProviderAuthStatusResponse
    
    // MARK: - Template Operations
    
    func getTemplates() async throws -> APITemplateListResponse
    
    func getTemplate(id: String) async throws -> APITemplate
    
    // MARK: - Skill Operations
    
    func getSkills() async throws -> [APISkill]
    
    // MARK: - Provisioning Operations
    
    func getProvisioning() async throws -> APIProvisioningResponse
    
    // MARK: - System Operations
    
    func getSystemStatus() async throws -> APISystemStatus
    
    func getSystemConfig() async throws -> APISystemConfig
    
    // MARK: - Event Streaming
    
    func subscribeToTaskEvents(id: String) async throws -> AsyncStream<APITaskEvent>
    
    func getTaskActivity(id: String, since: Int) async throws -> APIActivityResponse
}

/// Abstraction layer for cluster operations.
public protocol ClusterServiceProvider: Sendable {
    func handleAnnouncement(_ announcement: PeerAnnouncement) async throws
    func handleTaskUpdate(_ update: PeerTaskUpdate) async throws
    func handleDeparture(tunnelId: String) async throws
    func executeNow(_ request: ClusterExecuteNowRequest) async throws -> ClusterExecuteNowResponse
    func getClusterStatus() async throws -> APIClusterStatus
    func getClusterPeers() async throws -> [APIClusterPeer]
}
