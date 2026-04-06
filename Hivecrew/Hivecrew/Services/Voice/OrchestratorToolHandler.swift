//
//  OrchestratorToolHandler.swift
//  Hivecrew
//
//  Voice orchestrator tool declarations and dispatch.
//

import Foundation
import HivecrewLLM
import HivecrewVoice
import SwiftData
internal import AVFoundation

@MainActor
enum OrchestratorToolHandler {

    // MARK: - Tool Declarations

    static let toolDeclarations: [VoiceToolDeclaration] = [
        VoiceToolDeclaration(
            name: "create_task",
            description: "Create a new task for a worker agent. Each worker runs in a full macOS VM and can search the web, write files, run shell commands, and use GUI apps — so include the complete goal in one task rather than splitting simple multi-step work across workers. Returns the task ID and assigned worker name. To attach a captured reference image, pass its file path in the attachments array.",
            parameters: VoiceToolParameters(
                properties: [
                    "description": VoiceToolProperty(type: "string", description: "The full end-to-end goal for the worker, including all steps (e.g. research + write file)"),
                    "role": VoiceToolProperty(type: "string", description: "Short role label, e.g. 'UI Designer', 'Researcher'"),
                    "attachments": VoiceToolProperty(type: "string", description: "Comma-separated file paths to attach (e.g. from capture_reference)"),
                ],
                required: ["description", "role"]
            )
        ),
        VoiceToolDeclaration(
            name: "get_task_status",
            description: "Get the current status of a task by worker name or task ID.",
            parameters: VoiceToolParameters(
                properties: [
                    "query": VoiceToolProperty(type: "string", description: "Worker name, role, or task ID"),
                ],
                required: ["query"]
            )
        ),
        VoiceToolDeclaration(
            name: "send_instruction",
            description: "Send a follow-up instruction or answer to a worker's question.",
            parameters: VoiceToolParameters(
                properties: [
                    "query": VoiceToolProperty(type: "string", description: "Worker name or task ID"),
                    "message": VoiceToolProperty(type: "string", description: "The instruction or answer"),
                ],
                required: ["query", "message"]
            )
        ),
        VoiceToolDeclaration(
            name: "pause_task",
            description: "Pause a running task.",
            parameters: VoiceToolParameters(
                properties: [
                    "query": VoiceToolProperty(type: "string", description: "Worker name or task ID"),
                ],
                required: ["query"]
            )
        ),
        VoiceToolDeclaration(
            name: "resume_task",
            description: "Resume a paused task.",
            parameters: VoiceToolParameters(
                properties: [
                    "query": VoiceToolProperty(type: "string", description: "Worker name or task ID"),
                ],
                required: ["query"]
            )
        ),
        VoiceToolDeclaration(
            name: "cancel_task",
            description: "Cancel a task.",
            parameters: VoiceToolParameters(
                properties: [
                    "query": VoiceToolProperty(type: "string", description: "Worker name or task ID"),
                ],
                required: ["query"]
            )
        ),
        VoiceToolDeclaration(
            name: "capture_reference",
            description: "Capture the current video frame as a reference image for task creation.",
            parameters: VoiceToolParameters(properties: [:])
        ),
        VoiceToolDeclaration(
            name: "get_deliverables",
            description: "List output files from a completed task.",
            parameters: VoiceToolParameters(
                properties: [
                    "query": VoiceToolProperty(type: "string", description: "Worker name or task ID"),
                ],
                required: ["query"]
            )
        ),
        VoiceToolDeclaration(
            name: "focus_task",
            description: "Focus the UI task pane on a specific task.",
            parameters: VoiceToolParameters(
                properties: [
                    "query": VoiceToolProperty(type: "string", description: "Worker name or task ID"),
                ],
                required: ["query"]
            )
        ),
        VoiceToolDeclaration(
            name: "end_call",
            description: "End the current voice call. Will only succeed when there are no active or queued tasks remaining.",
            parameters: VoiceToolParameters(properties: [:])
        ),
    ]

    // MARK: - Dispatch

    static func handle(
        toolCall: VoiceToolCall,
        taskService: TaskService,
        workerRegistry: WorkerRegistry,
        videoSourceManager: VideoSourceManager,
        orchestrator: VoiceOrchestrator
    ) async -> String {
        let args = toolCall.arguments

        switch toolCall.name {
        case "create_task":
            return await handleCreateTask(
                description: args["description"] ?? "",
                role: args["role"] ?? "Worker",
                attachments: args["attachments"] ?? "",
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
            return await handleCaptureReference(videoSourceManager: videoSourceManager)

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

        default:
            return "Unknown tool: \(toolCall.name)"
        }
    }

    // MARK: - Handlers

    /// Same resolution as the dashboard prompt bar (`TaskInputView`): main chat provider + model.
    private static func resolvedMainModelSelection() -> (providerId: String, modelId: String)? {
        let defaults = UserDefaults.standard
        let providerId = (defaults.string(forKey: "lastSelectedProviderId") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !providerId.isEmpty else { return nil }

        let persisted = defaults.persistedModelId(for: providerId)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let modelId = persisted.isEmpty ? "moonshotai/kimi-k2.5" : persisted
        return (providerId, modelId)
    }

    private static func handleCreateTask(
        description: String,
        role: String,
        attachments: String,
        taskService: TaskService,
        workerRegistry: WorkerRegistry,
        orchestrator: VoiceOrchestrator
    ) async -> String {
        guard let (providerId, modelId) = resolvedMainModelSelection() else {
            return "Error: Main model not configured. Select a provider and model in the prompt bar or Settings."
        }

        // Parse attachments — may arrive as JSON array or comma/newline-separated paths
        let filePaths: [String]
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

        do {
            let task = try await taskService.createTask(
                description: description,
                providerId: providerId,
                modelId: modelId,
                attachedFilePaths: filePaths
            )
            let worker = workerRegistry.assignName(for: task.id, role: role)
            orchestrator.addRelevantTask(task.id)
            var result = "Task created. Worker \(worker.displayName) (\(worker.role)) is on it. Task ID: \(task.id)"
            if !filePaths.isEmpty {
                result += " (\(filePaths.count) file\(filePaths.count == 1 ? "" : "s") attached)"
            }
            return result
        } catch {
            return "Error creating task: \(error.localizedDescription)"
        }
    }

    private static func handleGetTaskStatus(
        query: String,
        taskService: TaskService,
        workerRegistry: WorkerRegistry
    ) async -> String {
        guard let worker = workerRegistry.resolve(query: query) else {
            return "No worker found matching '\(query)'"
        }
        guard let task = taskService.tasks.first(where: { $0.id == worker.id }) else {
            return "Task not found for worker \(worker.displayName)"
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

        return result
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
    ) async -> String {
        guard let worker = workerRegistry.resolve(query: query) else {
            return "No worker found matching '\(query)'"
        }

        // If the agent has a pending question, treat this as the answer.
        if let publisher = taskService.statePublishers[worker.id],
           let pending = publisher.pendingQuestion {
            let questionId = pending.id
            publisher.provideAnswer(message)
            taskService.answerQuestion(questionId)
            return "Answer sent to \(worker.displayName)"
        }

        guard let task = taskService.tasks.first(where: { $0.id == worker.id }) else {
            return "Task not found for \(worker.displayName)"
        }

        // If the agent is already running, inject as a live instruction.
        if let publisher = taskService.statePublishers[worker.id],
           task.status == .running || task.status == .paused {
            let existing = publisher.pendingInstructions?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let existing, !existing.isEmpty {
                publisher.pendingInstructions = existing + "\n" + message
            } else {
                publisher.pendingInstructions = message
            }
            return "Instruction sent to \(worker.displayName). It will be picked up on the next step."
        }

        // Task hasn't started yet — append to the task description so the
        // agent sees it in its initial system prompt.
        if task.status == .queued || task.status == .waitingForVM || task.status == .planning || task.status == .planReview {
            var blocks = task.retrievalInlineContextBlocks
            blocks.append("Voice instruction from user: \(message)")
            task.retrievalInlineContextBlocks = blocks
            try? taskService.modelContext?.save()
            return "Instruction added to \(worker.displayName)'s task. They will see it when they start."
        }

        return "Cannot send instructions to \(worker.displayName) — task status is \(task.status.displayName)."
    }

    private static func handlePauseTask(
        query: String,
        taskService: TaskService,
        workerRegistry: WorkerRegistry
    ) -> String {
        guard let worker = workerRegistry.resolve(query: query) else {
            return "No worker found matching '\(query)'"
        }
        // TaskService doesn't have a direct pause — we cancel the agent runner
        if let runner = taskService.runningAgents[worker.id] {
            runner.cancel()
            return "Paused \(worker.displayName)"
        }
        return "\(worker.displayName) is not currently running"
    }

    private static func handleResumeTask(
        query: String,
        taskService: TaskService,
        workerRegistry: WorkerRegistry
    ) async -> String {
        guard let worker = workerRegistry.resolve(query: query) else {
            return "No worker found matching '\(query)'"
        }
        if let task = taskService.tasks.first(where: { $0.id == worker.id }) {
            _ = try? await taskService.rerunTask(task)
            return "Resumed \(worker.displayName)"
        }
        return "Task not found for \(worker.displayName)"
    }

    private static func handleCancelTask(
        query: String,
        taskService: TaskService,
        workerRegistry: WorkerRegistry
    ) async -> String {
        guard let worker = workerRegistry.resolve(query: query) else {
            return "No worker found matching '\(query)'"
        }
        if let task = taskService.tasks.first(where: { $0.id == worker.id }) {
            await taskService.cancelTask(task)
            workerRegistry.deregister(taskId: worker.id)
            return "Cancelled \(worker.displayName)"
        }
        return "Task not found for \(worker.displayName)"
    }

    private static func handleCaptureReference(
        videoSourceManager: VideoSourceManager
    ) async -> String {
        guard videoSourceManager.activeSource != .none else {
            return "Error: No video source active. Ask the user to enable screen sharing or a camera via the input source picker."
        }

        let sourceDesc: String
        switch videoSourceManager.activeSource {
        case .camera(let id):
            let name = videoSourceManager.availableCameras.first(where: { $0.uniqueID == id })?.localizedName ?? id
            guard videoSourceManager.cameraCapture.isCapturing else {
                return "Error: Camera '\(name)' is selected but not capturing. The device may have disconnected."
            }
            sourceDesc = "camera '\(name)'"
        case .screen(let id):
            sourceDesc = "display \(id)"
        case .none:
            return "Error: No video source active."
        }

        guard let data = await videoSourceManager.captureCurrentFrame() else {
            return "Error: Failed to capture frame from \(sourceDesc). The source may not have produced any frames yet — wait a moment and try again."
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture_\(UUID().uuidString).jpg")
        do {
            try data.write(to: tempURL)
            return "Reference captured (\(data.count / 1024) KB): \(tempURL.path)"
        } catch {
            return "Error: Failed to save capture to disk: \(error.localizedDescription)"
        }
    }

    private static func handleGetDeliverables(
        query: String,
        taskService: TaskService,
        workerRegistry: WorkerRegistry
    ) -> String {
        guard let worker = workerRegistry.resolve(query: query) else {
            return "No worker found matching '\(query)'"
        }
        guard let task = taskService.tasks.first(where: { $0.id == worker.id }) else {
            return "Task not found for \(worker.displayName)"
        }
        guard let files = task.outputFilePaths, !files.isEmpty else {
            return "No deliverables yet for \(worker.displayName)"
        }
        return "Deliverables from \(worker.displayName):\n" + files.joined(separator: "\n")
    }

    private static func handleFocusTask(
        query: String,
        workerRegistry: WorkerRegistry,
        orchestrator: VoiceOrchestrator
    ) -> String {
        guard let worker = workerRegistry.resolve(query: query) else {
            return "No worker found matching '\(query)'"
        }
        orchestrator.focusedTaskId = worker.id
        return "Focused on \(worker.displayName)"
    }

    private static func handleEndCall(
        taskService: TaskService,
        orchestrator: VoiceOrchestrator
    ) -> String {
        let sessionTasks = taskService.tasks.filter { orchestrator.relevantTaskIds.contains($0.id) }
        let activeTasks = sessionTasks.filter { $0.status.isActive }

        if !activeTasks.isEmpty {
            let names = activeTasks.compactMap {
                orchestrator.workerRegistry.resolve(query: $0.id)?.displayName ?? $0.id
            }.joined(separator: ", ")
            return "Cannot end call — \(activeTasks.count) task(s) still active: \(names). Wait for them to finish or cancel them first."
        }

        orchestrator.endCallAfterSpeaking()
        return "Bye for now!"
    }
}
