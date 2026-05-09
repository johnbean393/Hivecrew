//
//  OrchestratorToolHandler.swift
//  Hivecrew
//
//  Voice orchestrator tool declarations and dispatch.
//

import Foundation
import AppKit
import HivecrewCore
import HivecrewLLM
import HivecrewVoice
import SwiftData
internal import AVFoundation

/// Result returned from a tool handler, carrying both the text sent back
/// to the voice model and an optional record for the transcript UI.
struct ToolCallResult: Sendable {
    let text: String
    let transcriptRecord: ToolUseRecord?

    /// JPEG image data to send to the voice model via the realtime input stream
    /// so it can visually analyze the image (e.g. for `read_file` on an image).
    let imageData: Data?

    init(text: String, transcriptRecord: ToolUseRecord?, imageData: Data? = nil) {
        self.text = text
        self.transcriptRecord = transcriptRecord
        self.imageData = imageData
    }

    static func textOnly(_ text: String) -> ToolCallResult {
        ToolCallResult(text: text, transcriptRecord: nil)
    }
}

@MainActor
enum OrchestratorToolHandler {
    private static let voiceTaskLaunchSnapshotDefaultsKey = "hivecrew.voiceTaskLaunchSnapshot"

    private struct VoiceTaskLaunchSnapshot: Codable {
        let providerId: String
        let modelId: String
        let executionTarget: TaskExecutionTarget
        let runtimeTarget: TaskRuntimeTarget?
        let reasoningEnabled: Bool?
        let reasoningEffort: String?
        let serviceTier: LLMServiceTier?
    }

    // MARK: - Tool Declarations

    static func toolDeclarations(supportsVisualInput: Bool = true) -> [VoiceToolDeclaration] {
        VoiceToolDeclaration.fromSharedToolSchemas()
            .filter { supportsVisualInput || $0.name != "capture_reference" }
    }

    // MARK: - Dispatch

    static func handle(
        toolCall: VoiceToolCall,
        taskService: TaskService,
        workerRegistry: WorkerRegistry,
        videoSourceManager: VideoSourceManager,
        orchestrator: VoiceOrchestrator
    ) async -> ToolCallResult {
        let args = toolCall.arguments

        switch toolCall.name {
        case "create_task":
            return await handleCreateTask(
                description: args["description"] ?? "",
                attachments: args["attachments"] ?? "",
                planFirst: args["plan_first"]?.lowercased() == "true",
                runtimeTarget: parseRuntimeTarget(args["runtime_target"] ?? args["runtimeTarget"]),
                taskService: taskService,
                workerRegistry: workerRegistry,
                orchestrator: orchestrator
            )

        case "get_task_status":
            return await handleGetTaskStatus(
                query: args["query"] ?? "",
                taskService: taskService,
                workerRegistry: workerRegistry
            )

        case "send_instruction":
            return await handleSendInstruction(
                query: args["query"] ?? "",
                message: args["message"] ?? "",
                taskService: taskService,
                workerRegistry: workerRegistry
            )

        case "pause_task":
            return handlePauseTask(
                query: args["query"] ?? "",
                taskService: taskService,
                workerRegistry: workerRegistry
            )

        case "resume_task":
            return await handleResumeTask(
                query: args["query"] ?? "",
                taskService: taskService,
                workerRegistry: workerRegistry
            )

        case "cancel_task":
            return await handleCancelTask(
                query: args["query"] ?? "",
                taskService: taskService,
                workerRegistry: workerRegistry
            )

        case "capture_reference":
            return await handleCaptureReference(
                videoSourceManager: videoSourceManager,
                supportsVisualInput: orchestrator.supportsVideoInput
            )

        case "get_deliverables":
            return handleGetDeliverables(
                query: args["query"] ?? "",
                taskService: taskService,
                workerRegistry: workerRegistry
            )

        case "focus_task":
            return handleFocusTask(
                query: args["query"] ?? "",
                workerRegistry: workerRegistry,
                orchestrator: orchestrator
            )

        case "end_call":
            return handleEndCall(
                taskService: taskService,
                orchestrator: orchestrator
            )

        case "search_files":
            return await handleSearchFiles(
                query: args["query"] ?? "",
                sourceFilter: args["source_filter"] ?? "",
                orchestrator: orchestrator
            )

        case "read_file":
            return await handleReadFile(
                path: args["path"] ?? "",
                supportsVisualInput: orchestrator.supportsVideoInput
            )

        case "search_file_content":
            return await handleSearchFileContent(
                path: args["path"] ?? "",
                query: args["query"] ?? ""
            )

        case "open_file":
            return handleOpenFile(
                path: args["path"] ?? "",
                reveal: args["reveal"] ?? "false"
            )

        default:
            return .textOnly("Unknown tool: \(toolCall.name)")
        }
    }

    // MARK: - Handlers

    /// Same resolution as the dashboard prompt bar (`TaskInputView`): main chat provider + model.
    private static func resolvedTaskLaunchSnapshot() -> VoiceTaskLaunchSnapshot? {
        let defaults = UserDefaults.standard

        if let data = defaults.data(forKey: voiceTaskLaunchSnapshotDefaultsKey),
           let snapshot = try? JSONDecoder().decode(VoiceTaskLaunchSnapshot.self, from: data) {
            let providerId = snapshot.providerId.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            let modelId = snapshot.modelId.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            guard !providerId.isEmpty, !modelId.isEmpty else { return nil }

            return VoiceTaskLaunchSnapshot(
                providerId: providerId,
                modelId: modelId,
                executionTarget: snapshot.executionTarget,
                runtimeTarget: snapshot.runtimeTarget ?? .automatic,
                reasoningEnabled: snapshot.reasoningEnabled,
                reasoningEffort: snapshot.reasoningEffort?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
                serviceTier: snapshot.serviceTier
            )
        }

        let providerId = (defaults.string(forKey: "lastSelectedProviderId") ?? "")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !providerId.isEmpty else { return nil }

        let persisted = defaults.persistedModelId(for: providerId)?
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
        let modelId = persisted.isEmpty ? "moonshotai/kimi-k2.5" : persisted
        return VoiceTaskLaunchSnapshot(
            providerId: providerId,
            modelId: modelId,
            executionTarget: .automatic,
            runtimeTarget: .automatic,
            reasoningEnabled: nil,
            reasoningEffort: nil,
            serviceTier: nil
        )
    }

    private static func parseRuntimeTarget(_ raw: String?) -> TaskRuntimeTarget? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else {
            return nil
        }
        switch value {
        case "auto", "automatic":
            return .automatic
        case "fast", "fastworker", "fast-worker", "fast_worker":
            return .fast
        case "app", "appworker", "app-worker", "app_worker":
            return .app
        case "vm", "isolated", "isolatedvm", "isolated-vm", "isolated_vm":
            return .isolatedVM
        default:
            return nil
        }
    }

    private static func handleCreateTask(
        description: String,
        attachments: String,
        planFirst: Bool,
        runtimeTarget: TaskRuntimeTarget?,
        taskService: TaskService,
        workerRegistry: WorkerRegistry,
        orchestrator: VoiceOrchestrator
    ) async -> ToolCallResult {
        guard let launchSnapshot = resolvedTaskLaunchSnapshot() else {
            return .textOnly("Error: Main model not configured. Select a provider and model in the prompt bar or Settings.")
        }

        var filePaths: [String]
        if attachments.isEmpty {
            filePaths = []
        } else if let data = attachments.data(using: .utf8),
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
            filePaths = arr.filter { !$0.isEmpty }
        } else {
            filePaths = attachments
                .components(separatedBy: CharacterSet(charactersIn: ",\n"))
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }

        let invalidPaths = filePaths.filter { !FileManager.default.fileExists(atPath: $0) }
        if !invalidPaths.isEmpty {
            let listed = invalidPaths.map { "  • \($0)" }.joined(separator: "\n")
            return .textOnly("Error: \(invalidPaths.count) attachment path\(invalidPaths.count == 1 ? " does" : "s do") not exist:\n\(listed)\nUse search_files to find the correct paths, then try again.")
        }

        do {
            let request = TaskCreationRequest(
                taskId: nil,
                description: description,
                providerId: launchSnapshot.providerId,
                modelId: launchSnapshot.modelId,
                executionTarget: launchSnapshot.executionTarget,
                runtimeTarget: runtimeTarget ?? launchSnapshot.runtimeTarget ?? .automatic,
                reasoningEnabled: launchSnapshot.reasoningEnabled,
                reasoningEffort: launchSnapshot.reasoningEffort,
                serviceTier: launchSnapshot.serviceTier,
                attachedFilePaths: filePaths,
                attachmentInfos: nil,
                outputDirectory: nil,
                mentionedSkillNames: [],
                referencedTaskIds: [],
                continuationSourceTaskId: nil,
                retrievalContextPackId: nil,
                retrievalInlineContextBlocks: [],
                retrievalContextAttachmentPaths: [],
                retrievalSelectedSuggestionIds: [],
                retrievalModeOverrides: [:],
                clusterReferenceContextBlocks: [],
                clusterReferenceFiles: [],
                planFirstEnabled: planFirst,
                planMarkdown: nil,
                planSelectedSkillNames: nil,
                localAccessGrants: [],
                clusterOwnerTaskId: nil,
                clusterExecutionAttempt: 0,
                clusterLeaseId: nil
            )
            
            let task: TaskRecord
            if await APIServerManager.shared.federatedProvider != nil {
                let taskId = try await APIServerManager.shared.createTaskViaCluster(request)
                guard let created = await taskService.tasks.first(where: { $0.id == taskId }) else {
                    return .textOnly("Task created via cluster but could not locate record.")
                }
                task = created
            } else {
                task = try await taskService.createTask(
                    description: description,
                    providerId: launchSnapshot.providerId,
                    modelId: launchSnapshot.modelId,
                    executionTarget: launchSnapshot.executionTarget,
                    runtimeTarget: runtimeTarget ?? launchSnapshot.runtimeTarget ?? .automatic,
                    reasoningEnabled: launchSnapshot.reasoningEnabled,
                    reasoningEffort: launchSnapshot.reasoningEffort,
                    serviceTier: launchSnapshot.serviceTier,
                    attachedFilePaths: filePaths,
                    planFirstEnabled: planFirst
                )
            }
            let worker = workerRegistry.assignName(for: task.id, taskTitle: task.title)
            orchestrator.addRelevantTask(task.id)
            var result = "Task created. Worker \(worker.displayName) is on it — \"\(task.title)\". Task ID: \(task.id)"
            if planFirst {
                result += " (plan-first mode — will create a plan for review before executing)"
            }
            if !filePaths.isEmpty {
                result += " (\(filePaths.count) file\(filePaths.count == 1 ? "" : "s") attached)"
            }
            let record = ToolUseRecord(
                toolName: "create_task",
                summary: "Assigned \(worker.displayName) — \(task.title)",
                detail: result,
                fileResults: []
            )
            return ToolCallResult(text: result, transcriptRecord: record)
        } catch {
            return .textOnly("Error creating task: \(error.localizedDescription)")
        }
    }

    private static func handleGetTaskStatus(
        query: String,
        taskService: TaskService,
        workerRegistry: WorkerRegistry
    ) async -> ToolCallResult {
        guard let worker = workerRegistry.resolve(query: query) else {
            return .textOnly("No worker found matching '\(query)'")
        }
        guard let task = taskService.tasks.first(where: { $0.id == worker.id }) else {
            return .textOnly("Task not found for worker \(worker.displayName)")
        }

        var result = "\(worker.label): status=\(task.status.displayName)"
        let publisher = taskService.statePublishers[worker.id]

        let isFinished = [TaskStatus.completed, .failed, .cancelled, .timedOut, .maxIterations, .planFailed].contains(task.status)
        if isFinished {
            let summary = publisher?.completionSummary ?? task.resultSummary ?? task.errorMessage ?? "No details available."
            result += ". Result: \(summary)"
            let deliverableCount = task.outputFilePaths?.count ?? 0
            if deliverableCount > 0 {
                result += " (\(deliverableCount) deliverable\(deliverableCount == 1 ? "" : "s"))"
            }
            let progress = publisher?.progressSummary ?? ""
            if !progress.isEmpty {
                result += ". \(progress)"
            }
        } else if let publisher {
            if publisher.planProgress != nil {
                result += ". \(publisher.progressSummary)"
            } else if publisher.status == .running {
                let summary = await generateQuickSummary(
                    digest: publisher.recentActivityDigest,
                    taskDescription: task.taskDescription,
                    taskService: taskService,
                    task: task
                )
                result += ". \(summary)"
            } else {
                result += ". \(publisher.progressSummary)"
            }
        } else {
            result += ", description=\"\(task.taskDescription)\""
        }

        let record = ToolUseRecord(
            toolName: "get_task_status",
            summary: "Checked status of \(worker.displayName)",
            detail: result,
            fileResults: []
        )
        return ToolCallResult(text: result, transcriptRecord: record)
    }

    /// Use the worker's LLM to produce a 1-2 sentence progress summary
    /// from the recent activity digest when no plan is available.
    private static func generateQuickSummary(
        digest: String,
        taskDescription: String,
        taskService: TaskService,
        task: TaskRecord
    ) async -> String {
        do {
            let client = try await taskService.createLLMClient(
                providerId: task.providerId,
                modelId: task.modelId
            )
            let prompt = """
            You are summarizing the progress of an AI agent for a voice assistant.
            Respond in 1-2 short sentences. Focus on what has been accomplished and what is being done now.

            Task: \(taskDescription)

            Recent activity log:
            \(digest)

            Progress summary:
            """
            let response = try await client.chat(
                messages: [LLMMessage.user(prompt)],
                tools: nil
            )
            if let text = response.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return text
            }
        } catch {
            // Fall through to basic summary
        }
        return "Step \(taskService.statePublishers[task.id]?.currentStep ?? 0), task in progress."
    }

    private static func handleSendInstruction(
        query: String,
        message: String,
        taskService: TaskService,
        workerRegistry: WorkerRegistry
    ) async -> ToolCallResult {
        guard let worker = workerRegistry.resolve(query: query) else {
            return .textOnly("No worker found matching '\(query)'")
        }

        if let publisher = taskService.statePublishers[worker.id],
           let pending = publisher.pendingQuestion {
            let questionId = pending.id
            publisher.provideAnswer(message)
            taskService.answerQuestion(questionId)
            let result = "Answer sent to \(worker.displayName)"
            let record = ToolUseRecord(
                toolName: "send_instruction",
                summary: "Answered \(worker.displayName)'s question",
                detail: result,
                fileResults: []
            )
            return ToolCallResult(text: result, transcriptRecord: record)
        }

        guard let task = taskService.tasks.first(where: { $0.id == worker.id }) else {
            return .textOnly("Task not found for \(worker.displayName)")
        }

        if let publisher = taskService.statePublishers[worker.id],
           task.status == .running || task.status == .paused {
            let existing = publisher.pendingInstructions?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let existing, !existing.isEmpty {
                publisher.pendingInstructions = existing + "\n" + message
            } else {
                publisher.pendingInstructions = message
            }
            let result = "Instruction sent to \(worker.displayName). It will be picked up on the next step."
            let record = ToolUseRecord(
                toolName: "send_instruction",
                summary: "Sent instruction to \(worker.displayName)",
                detail: result,
                fileResults: []
            )
            return ToolCallResult(text: result, transcriptRecord: record)
        }

        if task.status == .queued || task.status == .waitingForVM || task.status == .planning || task.status == .planReview {
            var blocks = task.retrievalInlineContextBlocks
            blocks.append("Voice instruction from user: \(message)")
            task.retrievalInlineContextBlocks = blocks
            try? taskService.modelContext?.save()
            let result = "Instruction added to \(worker.displayName)'s task. They will see it when they start."
            let record = ToolUseRecord(
                toolName: "send_instruction",
                summary: "Sent instruction to \(worker.displayName)",
                detail: result,
                fileResults: []
            )
            return ToolCallResult(text: result, transcriptRecord: record)
        }

        return .textOnly("Cannot send instructions to \(worker.displayName) — task status is \(task.status.displayName).")
    }

    private static func handlePauseTask(
        query: String,
        taskService: TaskService,
        workerRegistry: WorkerRegistry
    ) -> ToolCallResult {
        guard let worker = workerRegistry.resolve(query: query) else {
            return .textOnly("No worker found matching '\(query)'")
        }
        if let runner = taskService.runningAgents[worker.id] {
            runner.cancel()
            let result = "Paused \(worker.displayName)"
            let record = ToolUseRecord(
                toolName: "pause_task",
                summary: result,
                detail: result,
                fileResults: []
            )
            return ToolCallResult(text: result, transcriptRecord: record)
        }
        return .textOnly("\(worker.displayName) is not currently running")
    }

    private static func handleResumeTask(
        query: String,
        taskService: TaskService,
        workerRegistry: WorkerRegistry
    ) async -> ToolCallResult {
        guard let worker = workerRegistry.resolve(query: query) else {
            return .textOnly("No worker found matching '\(query)'")
        }
        if let task = taskService.tasks.first(where: { $0.id == worker.id }) {
            _ = try? await taskService.rerunTask(task)
            let result = "Resumed \(worker.displayName)"
            let record = ToolUseRecord(
                toolName: "resume_task",
                summary: result,
                detail: result,
                fileResults: []
            )
            return ToolCallResult(text: result, transcriptRecord: record)
        }
        return .textOnly("Task not found for \(worker.displayName)")
    }

    private static func handleCancelTask(
        query: String,
        taskService: TaskService,
        workerRegistry: WorkerRegistry
    ) async -> ToolCallResult {
        guard let worker = workerRegistry.resolve(query: query) else {
            return .textOnly("No worker found matching '\(query)'")
        }
        if let task = taskService.tasks.first(where: { $0.id == worker.id }) {
            await taskService.cancelTask(task)
            workerRegistry.deregister(taskId: worker.id)
            let result = "Cancelled \(worker.displayName)"
            let record = ToolUseRecord(
                toolName: "cancel_task",
                summary: result,
                detail: result,
                fileResults: []
            )
            return ToolCallResult(text: result, transcriptRecord: record)
        }
        return .textOnly("Task not found for \(worker.displayName)")
    }

    private static func handleCaptureReference(
        videoSourceManager: VideoSourceManager,
        supportsVisualInput: Bool
    ) async -> ToolCallResult {
        guard supportsVisualInput else {
            return .textOnly("Error: The selected voice provider does not support realtime image or video input.")
        }
        guard videoSourceManager.activeSource != .none else {
            return .textOnly("Error: No video source active. Ask the user to enable screen sharing or a camera via the input source picker.")
        }

        let sourceDesc: String
        switch videoSourceManager.activeSource {
        case .camera(let id):
            let name = videoSourceManager.availableCameras.first(where: { $0.uniqueID == id })?.localizedName ?? id
            guard videoSourceManager.cameraCapture.isCapturing else {
                return .textOnly("Error: Camera '\(name)' is selected but not capturing. The device may have disconnected.")
            }
            sourceDesc = "camera '\(name)'"
        case .screen(let id):
            sourceDesc = "display \(id)"
        case .none:
            return .textOnly("Error: No video source active.")
        }

        guard let data = await videoSourceManager.captureCurrentFrame() else {
            return .textOnly("Error: Failed to capture frame from \(sourceDesc). The source may not have produced any frames yet — wait a moment and try again.")
        }

        NotificationCenter.default.post(
            name: .screenCaptureAnimationRequested,
            object: nil,
            userInfo: ["imageData": data]
        )

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture_\(UUID().uuidString).jpg")
        do {
            try data.write(to: tempURL)
            let sizeKB = data.count / 1024
            let result = "Reference captured (\(sizeKB) KB): \(tempURL.path)"
            let record = ToolUseRecord(
                toolName: "capture_reference",
                summary: "Captured reference image (\(sizeKB) KB)",
                detail: result,
                fileResults: [],
                previewFilePath: tempURL.path
            )
            return ToolCallResult(text: result, transcriptRecord: record)
        } catch {
            return .textOnly("Error: Failed to save capture to disk: \(error.localizedDescription)")
        }
    }

    private static func handleGetDeliverables(
        query: String,
        taskService: TaskService,
        workerRegistry: WorkerRegistry
    ) -> ToolCallResult {
        guard let worker = workerRegistry.resolve(query: query) else {
            return .textOnly("No worker found matching '\(query)'")
        }
        guard let task = taskService.tasks.first(where: { $0.id == worker.id }) else {
            return .textOnly("Task not found for \(worker.displayName)")
        }
        guard let files = task.outputFilePaths, !files.isEmpty else {
            let result = "No deliverables yet for \(worker.displayName)"
            let record = ToolUseRecord(
                toolName: "get_deliverables",
                summary: "No deliverables yet",
                detail: result,
                fileResults: []
            )
            return ToolCallResult(text: result, transcriptRecord: record)
        }
        let result = "Deliverables from \(worker.displayName):\n" + files.joined(separator: "\n")
        let record = ToolUseRecord(
            toolName: "get_deliverables",
            summary: "Listed \(files.count) deliverable\(files.count == 1 ? "" : "s") from \(worker.displayName)",
            detail: result,
            fileResults: []
        )
        return ToolCallResult(text: result, transcriptRecord: record)
    }

    private static func handleFocusTask(
        query: String,
        workerRegistry: WorkerRegistry,
        orchestrator: VoiceOrchestrator
    ) -> ToolCallResult {
        guard let worker = workerRegistry.resolve(query: query) else {
            return .textOnly("No worker found matching '\(query)'")
        }
        orchestrator.focusedTaskId = worker.id
        let result = "Focused on \(worker.displayName)"
        let record = ToolUseRecord(
            toolName: "focus_task",
            summary: result,
            detail: result,
            fileResults: []
        )
        return ToolCallResult(text: result, transcriptRecord: record)
    }

    private static func handleEndCall(
        taskService: TaskService,
        orchestrator: VoiceOrchestrator
    ) -> ToolCallResult {
        let sessionTasks = taskService.tasks.filter { orchestrator.relevantTaskIds.contains($0.id) }
        let activeTasks = sessionTasks.filter { $0.status.isActive }

        if !activeTasks.isEmpty {
            let names = activeTasks.compactMap {
                orchestrator.workerRegistry.resolve(query: $0.id)?.displayName ?? $0.id
            }.joined(separator: ", ")
            return .textOnly("Cannot end call — \(activeTasks.count) task(s) still active: \(names). Wait for them to finish or cancel them first.")
        }

        orchestrator.endCallAfterSpeaking()
        let result = ""
        let record = ToolUseRecord(
            toolName: "end_call",
            summary: "Ending call",
            detail: result,
            fileResults: []
        )
        return ToolCallResult(text: result, transcriptRecord: record)
    }

    // MARK: - File Search

    private static func handleSearchFiles(
        query: String,
        sourceFilter: String,
        orchestrator: VoiceOrchestrator
    ) async -> ToolCallResult {
        guard !query.isEmpty else {
            return .textOnly("Error: query is required for search_files.")
        }

        let token: String
        do {
            token = try RetrievalDaemonManager.shared.daemonAuthToken()
        } catch {
            return .textOnly("File search unavailable — retrieval index is not running. You can still create the task without attachments, or ask the user for specific file paths.")
        }

        let baseURL = RetrievalDaemonManager.shared.daemonBaseURL()

        let sourceFilters: [String]?
        if !sourceFilter.isEmpty {
            sourceFilters = [sourceFilter]
        } else {
            sourceFilters = nil
        }

        let requestPayload = VoiceRetrievalSuggestRequest(
            query: query,
            sourceFilters: sourceFilters,
            limit: 8,
            typingMode: true,
            includeColdPartitionFallback: false
        )

        do {
            var urlRequest = URLRequest(url: baseURL.appending(path: "/api/v1/retrieval/suggest"))
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.setValue(token, forHTTPHeaderField: "X-Retrieval-Token")
            urlRequest.httpBody = try JSONEncoder().encode(requestPayload)
            urlRequest.timeoutInterval = 1.5

            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return .textOnly("File search failed — retrieval daemon returned an error. Proceed without attachments or ask the user for file paths.")
            }

            let suggestResponse = try JSONDecoder().decode(VoiceRetrievalSuggestResponse.self, from: data)
            let allSuggestions = suggestResponse.suggestions
            let suggestions = allSuggestions.filter { suggestion in
                let trimmedPath = suggestion.sourcePathOrHandle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmedPath.hasPrefix("/") else { return true }
                return FileManager.default.fileExists(atPath: trimmedPath)
            }
            let skippedCount = allSuggestions.count - suggestions.count

            guard !suggestions.isEmpty else {
                if skippedCount > 0 {
                    return .textOnly("Found only unavailable file results for '\(query)'. Those stale paths were skipped. Ask the user for more details or run search_files again.")
                }
                return .textOnly("No matching files found for '\(query)'. Ask the user for more details or proceed without attachments.")
            }

            let fileResults = suggestions.map { s in
                VoiceFileSearchResult(
                    id: s.id,
                    title: s.title,
                    path: s.sourcePathOrHandle,
                    sourceType: s.sourceType,
                    relevanceScore: s.relevanceScore
                )
            }

            var lines: [String] = ["Found \(suggestions.count) file(s):"]
            for (i, s) in suggestions.enumerated() {
                let score = String(format: "%.2f", s.relevanceScore)
                lines.append("\(i + 1). [\(score)] \(s.sourcePathOrHandle) — \(s.title)")
            }
            if skippedCount > 0 {
                lines.append("Skipped \(skippedCount) unavailable file result\(skippedCount == 1 ? "" : "s").")
            }
            lines.append("Pass desired paths to create_task via the attachments parameter.")
            let responseText = lines.joined(separator: "\n")

            let record = ToolUseRecord(
                toolName: "search_files",
                summary: "Found \(suggestions.count) file(s) for \"\(query)\"",
                detail: responseText,
                fileResults: fileResults
            )

            return ToolCallResult(text: responseText, transcriptRecord: record)
        } catch {
            return .textOnly("File search failed: \(error.localizedDescription). Proceed without attachments or ask the user for file paths.")
        }
    }

    // MARK: - File Reading

    private static func handleReadFile(path: String, supportsVisualInput: Bool) async -> ToolCallResult {
        guard !path.isEmpty else {
            return .textOnly("Error: path is required for read_file.")
        }

        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            return .textOnly("Error: File not found at \(path)")
        }

        do {
            let result = try await HostFileReader.read(at: url)
            let filename = url.lastPathComponent
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
            let sizeStr = ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)

            // For images, send the image data to the voice model so it can
            // visually analyze the content, matching the task agent's behavior.
            if result.hasImage {
                guard supportsVisualInput else {
                    let text = result.text + "\nThe selected voice provider does not support realtime image input, so this image was not loaded into the voice session."
                    let record = ToolUseRecord(
                        toolName: "read_file",
                        summary: "Read \(filename) (\(sizeStr))",
                        detail: result.text,
                        fileResults: [],
                        previewFilePath: path
                    )
                    return ToolCallResult(text: text, transcriptRecord: record)
                }
                let jpegData = imageAsJPEG(at: url)
                let text = result.text + "\nThe image has been loaded into your visual input. You can see it — describe its contents to the user."
                let record = ToolUseRecord(
                    toolName: "read_file",
                    summary: "Read \(filename) (\(sizeStr))",
                    detail: result.text,
                    fileResults: [],
                    previewFilePath: path
                )
                return ToolCallResult(text: text, transcriptRecord: record, imageData: jpegData)
            }

            var text = result.text
            if text.count > 10_000 {
                text = String(text.prefix(10_000)) + "\n\n[... truncated for voice context ...]"
            }

            let record = ToolUseRecord(
                toolName: "read_file",
                summary: "Read \(filename) (\(sizeStr))",
                detail: text,
                fileResults: [],
                previewFilePath: path
            )
            return ToolCallResult(text: text, transcriptRecord: record)
        } catch {
            return .textOnly("Error reading file: \(error.localizedDescription)")
        }
    }

    /// Convert an image file to JPEG Data for sending to the voice model.
    private static func imageAsJPEG(at url: URL) -> Data? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }

        let maxDim: CGFloat = 1024
        let w = CGFloat(bitmap.pixelsWide)
        let h = CGFloat(bitmap.pixelsHigh)
        if w > maxDim || h > maxDim {
            let scale = min(maxDim / w, maxDim / h)
            let newSize = NSSize(width: w * scale, height: h * scale)
            let resized = NSImage(size: newSize)
            resized.lockFocus()
            image.draw(in: NSRect(origin: .zero, size: newSize),
                       from: NSRect(origin: .zero, size: image.size),
                       operation: .copy, fraction: 1.0)
            resized.unlockFocus()
            guard let resizedTiff = resized.tiffRepresentation,
                  let resizedBitmap = NSBitmapImageRep(data: resizedTiff) else { return nil }
            return resizedBitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        }

        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }

    private static func handleSearchFileContent(
        path: String,
        query: String
    ) async -> ToolCallResult {
        guard !path.isEmpty else {
            return .textOnly("Error: path is required for search_file_content.")
        }
        guard !query.isEmpty else {
            return .textOnly("Error: query is required for search_file_content.")
        }

        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            return .textOnly("Error: File not found at \(path)")
        }

        do {
            let result = try await HostFileReader.readAndSearch(at: url, query: query)
            let filename = url.lastPathComponent

            let record = ToolUseRecord(
                toolName: "search_file_content",
                summary: "Searched \(filename) for \"\(query)\"",
                detail: result.text,
                fileResults: []
            )
            return ToolCallResult(text: result.text, transcriptRecord: record)
        } catch {
            return .textOnly("Error searching file: \(error.localizedDescription)")
        }
    }

    // MARK: - File Opening

    private static func handleOpenFile(path: String, reveal: String) -> ToolCallResult {
        guard !path.isEmpty else {
            return .textOnly("Error: path is required for open_file.")
        }

        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            return .textOnly("Error: File not found at \(path)")
        }

        let filename = url.lastPathComponent

        if reveal.lowercased() == "true" {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            let result = "Revealed \(filename) in Finder"
            let record = ToolUseRecord(
                toolName: "open_file",
                summary: result,
                detail: result,
                fileResults: []
            )
            return ToolCallResult(text: result, transcriptRecord: record)
        } else {
            NSWorkspace.shared.open(url)
            let result = "Opened \(filename)"
            let record = ToolUseRecord(
                toolName: "open_file",
                summary: result,
                detail: result,
                fileResults: []
            )
            return ToolCallResult(text: result, transcriptRecord: record)
        }
    }
}

// MARK: - Shared schema → HivecrewVoice

private extension VoiceToolDeclaration {
    static func fromSharedToolSchemas() -> [VoiceToolDeclaration] {
        SharedToolDeclarations.declarations.compactMap { VoiceToolDeclaration(sharedToolSchema: $0) }
    }

    init?(sharedToolSchema schema: [String: Any]) {
        guard let name = schema["name"] as? String,
              let description = schema["description"] as? String else { return nil }

        guard let paramsDict = schema["parameters"] as? [String: Any] else {
            self.init(name: name, description: description, parameters: nil)
            return
        }

        let type = paramsDict["type"] as? String ?? "object"
        let propertiesRaw = paramsDict["properties"] as? [String: Any] ?? [:]

        var voiceProperties: [String: VoiceToolProperty] = [:]
        for (key, value) in propertiesRaw {
            guard let propDict = value as? [String: Any],
                  let propType = propDict["type"] as? String,
                  let propDescription = propDict["description"] as? String else { continue }
            let enumValues = propDict["enum"] as? [String]
            voiceProperties[key] = VoiceToolProperty(type: propType, description: propDescription, enumValues: enumValues)
        }

        let required = paramsDict["required"] as? [String]
        let parameters = VoiceToolParameters(type: type, properties: voiceProperties, required: required)
        self.init(name: name, description: description, parameters: parameters)
    }
}
