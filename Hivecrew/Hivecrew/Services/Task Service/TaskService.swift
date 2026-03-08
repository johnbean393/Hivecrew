//
//  TaskService.swift
//  Hivecrew
//
//  Service for task orchestration, queue management, and VM assignment
//

import Foundation
import SwiftData
import Virtualization
import Combine
import HivecrewLLM
import HivecrewShared
import UserNotifications

struct TaskCreationRequest {
    let description: String
    let providerId: String
    let modelId: String
    let reasoningEnabled: Bool?
    let reasoningEffort: String?
    let serviceTier: LLMServiceTier?
    let attachedFilePaths: [String]
    let attachmentInfos: [AttachmentInfo]?
    let outputDirectory: String?
    let mentionedSkillNames: [String]
    let retrievalContextPackId: String?
    let retrievalInlineContextBlocks: [String]
    let retrievalContextAttachmentPaths: [String]
    let retrievalSelectedSuggestionIds: [String]
    let retrievalModeOverrides: [String: String]
    let planFirstEnabled: Bool
    let planMarkdown: String?
    let planSelectedSkillNames: [String]?
}

/// Service for managing tasks and agent execution
@MainActor
class TaskService: ObservableObject {
    
    // MARK: - Published State
    
    /// All tasks (active and completed)
    @Published var tasks: [TaskRecord] = []
    
    /// Currently running agents by task ID
    @Published var runningAgents: [String: AgentRunner] = [:]
    
    /// State publishers for active tasks by task ID
    @Published var statePublishers: [String: AgentStatePublisher] = [:]
    
    /// Active planning state publishers keyed by task ID (for plan-first mode)
    @Published var activePlanningPublishers: [String: PlanningStatePublisher] = [:]
    
    /// Pending questions from agents
    @Published var pendingQuestions: [AgentQuestion] = []
    
    /// Pending permission requests from agents (taskId -> request)
    @Published var pendingPermissions: [String: PermissionRequest] = [:]
    
    /// Number of VMs currently being created/started (prevents race conditions)
    var pendingVMCount: Int = 0
    
    /// Task IDs that are currently in the startTask flow (prevents duplicate processing)
    var tasksInProgress: Set<String> = []
    
    // MARK: - Dependencies
    
    let vmRuntime: AppVMRuntime
    let vmServiceClient: VMServiceClient
    private let titleGenerator: TaskTitleGenerator
    var modelContext: ModelContext?
    
    /// Skill manager for loading and matching skills
    let skillManager: SkillManager
    
    /// Combine subscriptions for state publisher observations
    var cancellables: [String: AnyCancellable] = [:]
    
    /// Connection timeout for GuestAgent (in seconds)
    let connectionTimeout: TimeInterval = 180 // 3 minutes
    
    /// Retry interval for GuestAgent connection (in seconds)
    let connectionRetryInterval: UInt64 = 5_000_000_000 // 5 seconds
    
    // MARK: - Initialization
    
    init(vmRuntime: AppVMRuntime = .shared, vmServiceClient: VMServiceClient = .shared) {
        self.vmRuntime = vmRuntime
        self.vmServiceClient = vmServiceClient
        self.titleGenerator = TaskTitleGenerator()
        self.skillManager = SkillManager()
    }
    
    /// Set the model context for SwiftData operations
    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
        loadTasks()
        
        // Clean up orphaned VMs on startup (after tasks are loaded)
        Task {
            await cleanupOrphanedVMs()
        }
    }
    
    // MARK: - Task Creation
    
    /// Create a new task from user description
    /// - Parameters:
    ///   - attachedFilePaths: File paths to attach (metadata stored now, files copied when session starts)
    ///   - attachmentInfos: Pre-processed attachment infos (for reruns)
    func createTask(
        description: String,
        providerId: String,
        modelId: String,
        reasoningEnabled: Bool? = nil,
        reasoningEffort: String? = nil,
        serviceTier: LLMServiceTier? = nil,
        attachedFilePaths: [String] = [],
        attachmentInfos: [AttachmentInfo]? = nil,
        outputDirectory: String? = nil,
        mentionedSkillNames: [String] = [],
        retrievalContextPackId: String? = nil,
        retrievalInlineContextBlocks: [String] = [],
        retrievalContextAttachmentPaths: [String] = [],
        retrievalSelectedSuggestionIds: [String] = [],
        retrievalModeOverrides: [String: String] = [:],
        planFirstEnabled: Bool = false,
        planMarkdown: String? = nil,
        planSelectedSkillNames: [String]? = nil
    ) async throws -> TaskRecord {
        let request = TaskCreationRequest(
            description: description,
            providerId: providerId,
            modelId: modelId,
            reasoningEnabled: reasoningEnabled,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier,
            attachedFilePaths: attachedFilePaths,
            attachmentInfos: attachmentInfos,
            outputDirectory: outputDirectory,
            mentionedSkillNames: mentionedSkillNames,
            retrievalContextPackId: retrievalContextPackId,
            retrievalInlineContextBlocks: retrievalInlineContextBlocks,
            retrievalContextAttachmentPaths: retrievalContextAttachmentPaths,
            retrievalSelectedSuggestionIds: retrievalSelectedSuggestionIds,
            retrievalModeOverrides: retrievalModeOverrides,
            planFirstEnabled: planFirstEnabled,
            planMarkdown: planMarkdown,
            planSelectedSkillNames: planSelectedSkillNames
        )

        guard let task = try await createTasks([request]).first else {
            throw TaskServiceError.noModelContext
        }
        return task
    }

    func createTasks(_ requests: [TaskCreationRequest]) async throws -> [TaskRecord] {
        guard !requests.isEmpty else {
            return []
        }
        guard let context = modelContext else {
            throw TaskServiceError.noModelContext
        }
        guard let workerProviderId = UserDefaults.standard.string(forKey: "workerModelProviderId"),
              let workerModelId = UserDefaults.standard.string(forKey: "workerModelId"),
              !workerProviderId.isEmpty,
              !workerModelId.isEmpty else {
            throw TaskServiceError.workerModelNotConfigured
        }

        var createdTasks: [(task: TaskRecord, request: TaskCreationRequest)] = []
        createdTasks.reserveCapacity(requests.count)

        for (index, existingTask) in tasks.enumerated() {
            existingTask.sortOrder = index + requests.count
        }

        for (index, request) in requests.enumerated() {
            let quickTitle = titleGenerator.generateQuickTitle(from: request.description)
            let mergedAttachedFilePaths = Array(
                Set(request.attachedFilePaths + request.retrievalContextAttachmentPaths)
            ).sorted()

            let preparedInfos: [AttachmentInfo]?
            if let existingInfos = request.attachmentInfos {
                preparedInfos = existingInfos
            } else if !mergedAttachedFilePaths.isEmpty {
                preparedInfos = AttachmentManager.prepareAttachmentInfos(filePaths: mergedAttachedFilePaths)
            } else {
                preparedInfos = nil
            }

            let task = TaskRecord(
                title: quickTitle,
                taskDescription: request.description,
                status: .queued,
                sortOrder: index,
                providerId: request.providerId,
                modelId: request.modelId,
                reasoningEnabled: request.reasoningEnabled,
                reasoningEffort: request.reasoningEffort,
                serviceTier: request.serviceTier,
                attachmentInfos: preparedInfos,
                outputDirectory: request.outputDirectory,
                mentionedSkillNames: request.mentionedSkillNames.isEmpty ? nil : request.mentionedSkillNames,
                retrievalContextPackId: request.retrievalContextPackId,
                retrievalInlineContextBlocks: request.retrievalInlineContextBlocks,
                retrievalContextAttachmentPaths: request.retrievalContextAttachmentPaths.isEmpty ? nil : request.retrievalContextAttachmentPaths,
                retrievalSelectedSuggestionIds: request.retrievalSelectedSuggestionIds.isEmpty ? nil : request.retrievalSelectedSuggestionIds,
                retrievalModeOverrides: request.retrievalModeOverrides.isEmpty ? nil : request.retrievalModeOverrides,
                planFirstEnabled: request.planFirstEnabled
            )

            if let planMarkdown = request.planMarkdown {
                task.planMarkdown = planMarkdown
                task.planSelectedSkillNames = request.planSelectedSkillNames
            }

            context.insert(task)
            createdTasks.append((task, request))
        }

        try context.save()

        tasks.insert(contentsOf: createdTasks.map(\.task), at: 0)
        objectWillChange.send()

        for created in createdTasks {
            let task = created.task
            let request = created.request

            Task {
                await generateAndUpdateTitle(
                    for: task,
                    description: request.description,
                    providerId: request.providerId,
                    modelId: request.modelId
                )
            }

            Task {
                await startTask(task)
            }
        }

        print("TaskService: Created \(createdTasks.count) task(s)")
        return createdTasks.map(\.task)
    }
    
    /// Validate attachments for a task rerun
    /// - Parameter originalTask: The task to validate
    /// - Returns: Validation result indicating which attachments are valid/missing
    func validateRerunAttachments(_ originalTask: TaskRecord) -> RerunAttachmentValidation {
        return AttachmentManager.validateAttachmentsForRerun(originalInfos: originalTask.attachmentInfos)
    }
    
    /// Create a new task with the same parameters as a previous task
    /// - Parameter originalTask: The task to rerun
    /// - Returns: The newly created task
    /// - Note: Use `validateRerunAttachments` first to check for missing files
    func rerunTask(_ originalTask: TaskRecord) async throws -> TaskRecord {
        try await rerunTask(
            originalTask,
            providerId: originalTask.providerId,
            modelId: originalTask.modelId
        )
    }
    
    /// Create a new task with the same parameters as a previous task, using a specific provider/model
    /// - Parameters:
    ///   - originalTask: The task to rerun
    ///   - providerId: Provider ID to use for the new task
    ///   - modelId: Model ID to use for the new task
    /// - Returns: The newly created task
    /// - Note: Use `validateRerunAttachments` first to check for missing files
    func rerunTask(
        _ originalTask: TaskRecord,
        providerId: String,
        modelId: String,
        reasoningEnabled: Bool? = nil,
        reasoningEffort: String? = nil,
        serviceTier: LLMServiceTier? = nil
    ) async throws -> TaskRecord {
        // Prepare attachment infos for rerun (validates files exist, keeps references)
        // Actual copying happens when the new session starts
        let originalInfos = originalTask.attachmentInfos
        let newInfos = AttachmentManager.prepareAttachmentsForRerun(originalInfos: originalInfos)
        
        return try await createRerunTask(
            from: originalTask,
            providerId: providerId,
            modelId: modelId,
            reasoningEnabled: reasoningEnabled ?? originalTask.reasoningEnabled,
            reasoningEffort: reasoningEffort ?? originalTask.reasoningEffort,
            serviceTier: serviceTier ?? originalTask.serviceTier,
            attachmentInfos: newInfos.isEmpty ? nil : newInfos
        )
    }
    
    /// Create a new task with the same parameters as a previous task, using provided attachments
    /// Used when user has resolved missing attachments
    /// - Parameters:
    ///   - originalTask: The task to rerun
    ///   - resolvedAttachments: Resolved attachment infos (after user selected replacements)
    /// - Returns: The newly created task
    func rerunTask(_ originalTask: TaskRecord, withResolvedAttachments resolvedAttachments: [AttachmentInfo]) async throws -> TaskRecord {
        try await rerunTask(
            originalTask,
            providerId: originalTask.providerId,
            modelId: originalTask.modelId,
            withResolvedAttachments: resolvedAttachments
        )
    }
    
    /// Create a new task with the same parameters as a previous task, using provided attachments and provider/model
    /// - Parameters:
    ///   - originalTask: The task to rerun
    ///   - providerId: Provider ID to use for the new task
    ///   - modelId: Model ID to use for the new task
    ///   - resolvedAttachments: Resolved attachment infos (after user selected replacements)
    /// - Returns: The newly created task
    func rerunTask(
        _ originalTask: TaskRecord,
        providerId: String,
        modelId: String,
        reasoningEnabled: Bool? = nil,
        reasoningEffort: String? = nil,
        serviceTier: LLMServiceTier? = nil,
        withResolvedAttachments resolvedAttachments: [AttachmentInfo]
    ) async throws -> TaskRecord {
        return try await createRerunTask(
            from: originalTask,
            providerId: providerId,
            modelId: modelId,
            reasoningEnabled: reasoningEnabled ?? originalTask.reasoningEnabled,
            reasoningEffort: reasoningEffort ?? originalTask.reasoningEffort,
            serviceTier: serviceTier ?? originalTask.serviceTier,
            attachmentInfos: resolvedAttachments.isEmpty ? nil : resolvedAttachments
        )
    }
    
    /// Shared helper for creating rerun tasks while preserving all non-model task options.
    private func createRerunTask(
        from originalTask: TaskRecord,
        providerId: String,
        modelId: String,
        reasoningEnabled: Bool?,
        reasoningEffort: String?,
        serviceTier: LLMServiceTier?,
        attachmentInfos: [AttachmentInfo]?
    ) async throws -> TaskRecord {
        // If the original task had a plan, reuse it to skip the planning phase
        // and start execution directly
        return try await createTask(
            description: originalTask.taskDescription,
            providerId: providerId,
            modelId: modelId,
            reasoningEnabled: reasoningEnabled,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier,
            attachmentInfos: attachmentInfos,
            outputDirectory: originalTask.outputDirectory,
            mentionedSkillNames: originalTask.mentionedSkillNames ?? [],
            retrievalContextPackId: originalTask.retrievalContextPackId,
            retrievalInlineContextBlocks: originalTask.retrievalInlineContextBlocks,
            retrievalContextAttachmentPaths: originalTask.retrievalContextAttachmentPaths ?? [],
            retrievalSelectedSuggestionIds: originalTask.retrievalSelectedSuggestionIds ?? [],
            retrievalModeOverrides: originalTask.retrievalModeOverrides,
            planFirstEnabled: originalTask.planFirstEnabled,
            planMarkdown: originalTask.planMarkdown,
            planSelectedSkillNames: originalTask.planSelectedSkillNames
        )
    }

    /// Persist a user-edited title for an existing task.
    func renameTask(_ task: TaskRecord, to newTitle: String) {
        let trimmedTitle = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        guard task.title != trimmedTitle else { return }

        task.title = trimmedTitle
        try? modelContext?.save()
        objectWillChange.send()
    }

    /// Persist a drag-and-drop reorder from the dashboard task list.
    func moveTasks(fromOffsets sourceOffsets: IndexSet, toOffset destination: Int) {
        guard !sourceOffsets.isEmpty else { return }

        let movingTasks = sourceOffsets.sorted().map { tasks[$0] }
        var reorderedTasks = tasks.enumerated()
            .filter { !sourceOffsets.contains($0.offset) }
            .map(\.element)

        let adjustedDestination = max(
            0,
            min(destination - sourceOffsets.filter { $0 < destination }.count, reorderedTasks.count)
        )
        reorderedTasks.insert(contentsOf: movingTasks, at: adjustedDestination)

        applyTaskOrder(reorderedTasks)
    }
    
    /// Generate a better title using LLM and update the task
    private func generateAndUpdateTitle(for task: TaskRecord, description: String, providerId: String, modelId: String) async {
        do {
            let existingTitle = task.title
            // Use required worker model for background title generation.
            let client = try await createWorkerLLMClient(fallbackProviderId: providerId, fallbackModelId: modelId)
            let betterTitle = try await titleGenerator.generateTitle(from: description, using: client)
            
            // Do not overwrite a title that changed while generation was running.
            guard task.title == existingTitle else { return }

            // Update the task title if LLM generation succeeded
            task.title = betterTitle
            try? modelContext?.save()
            objectWillChange.send()
        } catch {
            // Keep the quick title if LLM generation fails
            print("TaskService: Failed to generate LLM title: \(error)")
        }
    }
    
    // MARK: - Data Loading
    
    /// Load tasks from SwiftData
    private func loadTasks() {
        guard let context = modelContext else { return }
        
        do {
            let descriptor = FetchDescriptor<TaskRecord>(
                sortBy: [
                    SortDescriptor(\.sortOrder, order: .forward),
                    SortDescriptor(\.createdAt, order: .reverse)
                ]
            )
            tasks = try context.fetch(descriptor)
            normalizeTaskOrderIfNeeded()
            
            // Recover orphaned tasks - tasks that were active when the app was killed
            recoverOrphanedTasks()
        } catch {
            print("TaskService: Failed to load tasks: \(error)")
        }
    }
    
    /// Recover tasks that were left in an active state from a previous session
    /// - Queued/WaitingForVM tasks: leave them queued for the startup sheet
    /// - Running tasks: mark as queued (so they can be restarted from startup sheet)
    /// - Paused tasks with missing VMs: requeue them (VM was lost)
    /// - Paused tasks with existing VMs: keep them paused (can be resumed)
    private func recoverOrphanedTasks() {
        guard let context = modelContext else { return }
        
        var recovered = 0
        var pausedKept = 0
        var pausedRequeued = 0
        
        for task in tasks where task.status.isActive {
            // If the task is in an active state but we don't have a running agent for it,
            // it means the app was killed while the task was running
            if runningAgents[task.id] == nil {
                if task.status == .running {
                    // Running task was interrupted - requeue it
                    task.status = .queued
                    task.startedAt = nil
                    task.completedAt = nil
                    task.assignedVMId = nil
                    task.errorMessage = "Task was interrupted (app was closed) - requeued"
                    recovered += 1
                } else if task.status == .paused {
                    // Paused task - check if VM still exists
                    if let vmId = task.assignedVMId, vmDirectoryExists(vmId) {
                        // VM still exists, keep the task paused so it can be resumed
                        pausedKept += 1
                    } else {
                        // VM is missing, requeue the task
                        task.status = .queued
                        task.startedAt = nil
                        task.completedAt = nil
                        task.assignedVMId = nil
                        task.errorMessage = "Paused task's VM was lost - requeued"
                        pausedRequeued += 1
                    }
                }
                // Queued and WaitingForVM tasks stay as-is (will appear in startup sheet)
            }
        }
        
        if recovered > 0 || pausedRequeued > 0 {
            try? context.save()
            print("TaskService: Recovered \(recovered) running task(s), kept \(pausedKept) paused task(s), requeued \(pausedRequeued) paused task(s) with missing VMs")
            objectWillChange.send()
        }
    }
    
    // MARK: - Query Helpers
    
    /// Get active tasks (queued, waiting, or running)
    var activeTasks: [TaskRecord] {
        tasks.filter { isTaskEffectivelyActive($0) }
    }
    
    /// Get completed tasks (success, failed, or cancelled)
    var completedTasks: [TaskRecord] {
        tasks.filter { !$0.status.isActive }
    }
    
    /// Get queued tasks (for startup sheet)
    var queuedTasks: [TaskRecord] {
        tasks.filter { $0.status == .queued || $0.status == .waitingForVM }
    }

    /// Derive an effective status that accounts for live agent state.
    func effectiveStatus(for task: TaskRecord) -> TaskStatus {
        switch task.status {
        case .planning, .planReview, .planFailed:
            return task.status
        default:
            break
        }

        guard let publisher = statePublishers[task.id] else {
            return task.status
        }

        switch publisher.status {
        case .running:
            return .running
        case .paused:
            return .paused
        case .completed:
            return .completed
        case .failed:
            return .failed
        case .cancelled:
            return .cancelled
        case .connecting:
            return .waitingForVM
        case .idle:
            return task.status
        }
    }

    /// True when the task is effectively active based on runtime state.
    func isTaskEffectivelyActive(_ task: TaskRecord) -> Bool {
        effectiveStatus(for: task).isActive
    }
    
    /// Get the state publisher for a task
    func statePublisher(for taskId: String) -> AgentStatePublisher? {
        statePublishers[taskId]
    }
    
    /// Answer a pending question
    func answerQuestion(_ questionId: String) {
        if let index = pendingQuestions.firstIndex(where: { $0.id == questionId }) {
            pendingQuestions.remove(at: index)
            // The answer callback in ToolExecutor will handle resuming the agent
        }
    }
    
    /// Respond to a pending permission request
    func respondToPermission(taskId: String, approved: Bool) {
        if pendingPermissions.removeValue(forKey: taskId) != nil {
            // Find the state publisher and respond
            if let publisher = statePublishers[taskId] {
                publisher.providePermissionResponse(approved)
            }
        }
    }

    private func normalizeTaskOrderIfNeeded() {
        let needsNormalization = tasks.enumerated().contains { index, task in
            task.sortOrder != index
        }

        guard needsNormalization else { return }
        applyTaskOrder(tasks)
    }

    private func applyTaskOrder(_ orderedTasks: [TaskRecord]) {
        tasks = orderedTasks

        for (index, task) in tasks.enumerated() {
            task.sortOrder = index
        }

        try? modelContext?.save()
        objectWillChange.send()
    }
}

// MARK: - CreateWorkerClientProtocol Conformance

extension TaskService: CreateWorkerClientProtocol {
    // Already implemented in TaskService+VMManagement.swift
}
