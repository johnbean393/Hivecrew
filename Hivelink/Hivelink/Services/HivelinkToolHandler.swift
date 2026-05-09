//
//  HivelinkToolHandler.swift
//  Hivelink
//
//  Voice orchestrator tool dispatch for iOS. Adapts the macOS
//  OrchestratorToolHandler for Hivelink's remote-peer task model.
//

import Foundation
import UIKit
import HivecrewAPIModels
import HivecrewCore
import HivecrewVoice

struct HivelinkToolCallResult: Sendable {
    let text: String
    let transcriptRecord: ToolUseRecord?
    let imageData: Data?

    init(text: String, transcriptRecord: ToolUseRecord?, imageData: Data? = nil) {
        self.text = text
        self.transcriptRecord = transcriptRecord
        self.imageData = imageData
    }

    static func textOnly(_ text: String) -> HivelinkToolCallResult {
        HivelinkToolCallResult(text: text, transcriptRecord: nil)
    }
}

@MainActor
enum HivelinkToolHandler {
    private static let voiceTaskLaunchSnapshotDefaultsKey = "hivelink.voiceTaskLaunchSnapshot"

    private struct VoiceTaskLaunchSnapshot: Codable {
        let providerName: String
        let modelId: String
        let executionTarget: TaskExecutionTarget
        let runtimeTarget: TaskRuntimeTarget?
        let reasoningEnabled: Bool?
        let reasoningEffort: String?
    }

    static let unsupportedTools: Set<String> = ["search_files", "open_file", "search_file_content", "read_file", "get_deliverables"]
    static func toolDeclarations(supportsVisualInput: Bool = true) -> [VoiceToolDeclaration] {
        fromSharedToolSchemas().filter {
            !unsupportedTools.contains($0.name)
                && (supportsVisualInput || $0.name != "capture_reference")
        }
    }

    private static func resolvedTaskLaunchSnapshot() -> VoiceTaskLaunchSnapshot? {
        let defaults = UserDefaults.standard

        if let data = defaults.data(forKey: voiceTaskLaunchSnapshotDefaultsKey),
           let snapshot = try? JSONDecoder().decode(VoiceTaskLaunchSnapshot.self, from: data) {
            let providerName = snapshot.providerName.trimmingCharacters(in: .whitespacesAndNewlines)
            let modelId = snapshot.modelId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !providerName.isEmpty, !modelId.isEmpty else { return nil }

            return VoiceTaskLaunchSnapshot(
                providerName: providerName,
                modelId: modelId,
                executionTarget: snapshot.executionTarget,
                runtimeTarget: snapshot.runtimeTarget,
                reasoningEnabled: snapshot.reasoningEnabled,
                reasoningEffort: snapshot.reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let providerName = defaults.string(forKey: "hivelink.lastProviderName")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let modelId = defaults.string(forKey: "hivelink.lastModelId")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !providerName.isEmpty, !modelId.isEmpty else { return nil }

        return VoiceTaskLaunchSnapshot(
            providerName: providerName,
            modelId: modelId,
            executionTarget: .remoteFirst,
            runtimeTarget: .automatic,
            reasoningEnabled: nil,
            reasoningEffort: defaults.string(forKey: "hivelink.reasoningEffort")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // MARK: - Dispatch

    static func handle(
        toolCall: VoiceToolCall,
        taskService: HivelinkTaskService,
        workerRegistry: WorkerRegistry,
        cameraCapture: CameraCaptureManager,
        orchestrator: HivelinkVoiceOrchestrator
    ) async -> HivelinkToolCallResult {
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
                workerRegistry: workerRegistry,
                orchestrator: orchestrator
            )

        case "pause_task":
            return await handlePauseTask(
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

        case "approve_plan":
            return await handleApprovePlan(
                query: args["query"] ?? "",
                taskService: taskService,
                workerRegistry: workerRegistry
            )

        case "reject_plan":
            return await handleRejectPlan(
                query: args["query"] ?? "",
                taskService: taskService,
                workerRegistry: workerRegistry
            )

        case "approve_writeback":
            return await handleApproveWriteback(
                query: args["query"] ?? "",
                taskService: taskService,
                workerRegistry: workerRegistry
            )

        case "discard_writeback":
            return await handleDiscardWriteback(
                query: args["query"] ?? "",
                taskService: taskService,
                workerRegistry: workerRegistry
            )

        case "capture_reference":
            return await handleCaptureReference(
                cameraCapture: cameraCapture,
                orchestrator: orchestrator
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
            return .textOnly("Unknown tool: \(toolCall.name)")
        }
    }

    // MARK: - Create Task

    private static func handleCreateTask(
        description: String,
        attachments: String,
        planFirst: Bool,
        runtimeTarget: TaskRuntimeTarget?,
        taskService: HivelinkTaskService,
        workerRegistry: WorkerRegistry,
        orchestrator: HivelinkVoiceOrchestrator
    ) async -> HivelinkToolCallResult {
        guard let launchSnapshot = resolvedTaskLaunchSnapshot() else {
            return .textOnly("Error: Default model not configured. Go to Settings → Defaults and select a provider and model.")
        }

        let providerId = "\(TaskRecord.remoteOnlyProviderPrefix)\(launchSnapshot.providerName)"

        var filePaths: [String] = []
        if !attachments.isEmpty {
            if let data = attachments.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
                filePaths = arr.filter { !$0.isEmpty }
            } else {
                filePaths = attachments
                    .components(separatedBy: CharacterSet(charactersIn: ",\n"))
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        }

        do {
            let request = TaskCreationRequest(
                description: description,
                providerId: providerId,
                modelId: launchSnapshot.modelId,
                executionTarget: launchSnapshot.executionTarget,
                runtimeTarget: runtimeTarget ?? launchSnapshot.runtimeTarget ?? .automatic,
                reasoningEnabled: launchSnapshot.reasoningEnabled,
                reasoningEffort: launchSnapshot.reasoningEffort,
                attachedFilePaths: filePaths,
                planFirstEnabled: planFirst
            )

            let created = try await taskService.createTasks([request])
            guard let task = created.first else {
                return .textOnly("Error: Task creation returned no record.")
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
            return HivelinkToolCallResult(text: result, transcriptRecord: record)
        } catch {
            return .textOnly("Error creating task: \(error.localizedDescription)")
        }
    }

    private static func parseRuntimeTarget(_ rawValue: String?) -> TaskRuntimeTarget? {
        guard let rawValue else { return nil }
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")

        switch normalized {
        case "auto", "automatic":
            return .automatic
        case "fast", "fast_worker", "fastworker":
            return .fast
        case "app", "app_worker", "appworker":
            return .app
        case "vm", "isolated_vm", "isolatedvm", "isolated":
            return .isolatedVM
        default:
            return nil
        }
    }

    // MARK: - Get Task Status

    private static func handleGetTaskStatus(
        query: String,
        taskService: HivelinkTaskService,
        workerRegistry: WorkerRegistry
    ) async -> HivelinkToolCallResult {
        guard let worker = workerRegistry.resolve(query: query) else {
            return .textOnly("No worker found matching '\(query)'")
        }
        guard let task = taskService.tasks.first(where: { $0.id == worker.id }) else {
            return .textOnly("Task not found for worker \(worker.displayName)")
        }

        var result = "\(worker.label): status=\(task.status.displayName)"

        let isFinished = [TaskStatus.completed, .failed, .cancelled, .timedOut, .maxIterations, .planFailed].contains(task.status)
        if isFinished {
            let summary = task.resultSummary ?? task.errorMessage ?? "No details available."
            result += ". Result: \(summary)"
        } else {
            let events = taskService.peerConnectionManager?.events(for: task.id) ?? []
            if let lastEvent = events.last {
                let eventMessage: String
                if case .string(let msg) = lastEvent.data["message"] {
                    eventMessage = msg
                } else {
                    eventMessage = lastEvent.type.rawValue
                }
                result += ". Latest activity: \(eventMessage)"
            } else {
                result += ", description=\"\(task.taskDescription.prefix(200))\""
            }
        }

        let record = ToolUseRecord(
            toolName: "get_task_status",
            summary: "Checked status of \(worker.displayName)",
            detail: result,
            fileResults: []
        )
        return HivelinkToolCallResult(text: result, transcriptRecord: record)
    }

    // MARK: - Send Instruction

    private static func handleSendInstruction(
        query: String,
        message: String,
        taskService: HivelinkTaskService,
        workerRegistry: WorkerRegistry,
        orchestrator: HivelinkVoiceOrchestrator
    ) async -> HivelinkToolCallResult {
        guard let worker = workerRegistry.resolve(query: query) else {
            return .textOnly("No worker found matching '\(query)'")
        }
        guard let task = taskService.tasks.first(where: { $0.id == worker.id }) else {
            return .textOnly("Task not found for \(worker.displayName)")
        }

        guard task.status == .running || task.status == .paused || task.status == .queued ||
              task.status == .waitingForVM || task.status == .planning || task.status == .planReview else {
            return .textOnly("Cannot send instructions to \(worker.displayName) — task status is \(task.status.displayName).")
        }

        if let question = taskService.peerConnectionManager?.pendingQuestion(for: task.id) {
            await taskService.answerQuestion(task, questionId: question.id, answer: message)
        } else {
            await taskService.sendInstruction(message, to: task)
        }

        let result = "Instruction sent to \(worker.displayName)."
        let record = ToolUseRecord(
            toolName: "send_instruction",
            summary: "Sent instruction to \(worker.displayName)",
            detail: result,
            fileResults: []
        )
        return HivelinkToolCallResult(text: result, transcriptRecord: record)
    }

    // MARK: - Pause / Resume / Cancel

    private static func handlePauseTask(
        query: String,
        taskService: HivelinkTaskService,
        workerRegistry: WorkerRegistry
    ) async -> HivelinkToolCallResult {
        guard let worker = workerRegistry.resolve(query: query) else {
            return .textOnly("No worker found matching '\(query)'")
        }
        guard let task = taskService.tasks.first(where: { $0.id == worker.id }) else {
            return .textOnly("Task not found for \(worker.displayName)")
        }
        await taskService.pauseTask(task)
        let result = "Paused \(worker.displayName)"
        let record = ToolUseRecord(
            toolName: "pause_task",
            summary: result,
            detail: result,
            fileResults: []
        )
        return HivelinkToolCallResult(text: result, transcriptRecord: record)
    }

    private static func handleResumeTask(
        query: String,
        taskService: HivelinkTaskService,
        workerRegistry: WorkerRegistry
    ) async -> HivelinkToolCallResult {
        guard let worker = workerRegistry.resolve(query: query) else {
            return .textOnly("No worker found matching '\(query)'")
        }
        guard let task = taskService.tasks.first(where: { $0.id == worker.id }) else {
            return .textOnly("Task not found for \(worker.displayName)")
        }
        await taskService.resumeTask(task)
        let result = "Resumed \(worker.displayName)"
        let record = ToolUseRecord(
            toolName: "resume_task",
            summary: result,
            detail: result,
            fileResults: []
        )
        return HivelinkToolCallResult(text: result, transcriptRecord: record)
    }

    private static func handleCancelTask(
        query: String,
        taskService: HivelinkTaskService,
        workerRegistry: WorkerRegistry
    ) async -> HivelinkToolCallResult {
        guard let worker = workerRegistry.resolve(query: query) else {
            return .textOnly("No worker found matching '\(query)'")
        }
        guard let task = taskService.tasks.first(where: { $0.id == worker.id }) else {
            return .textOnly("Task not found for \(worker.displayName)")
        }
        await taskService.cancelTask(task)
        workerRegistry.deregister(taskId: worker.id)
        let result = "Cancelled \(worker.displayName)"
        let record = ToolUseRecord(
            toolName: "cancel_task",
            summary: result,
            detail: result,
            fileResults: []
        )
        return HivelinkToolCallResult(text: result, transcriptRecord: record)
    }

    // MARK: - Plan Approval

    private static func handleApprovePlan(
        query: String,
        taskService: HivelinkTaskService,
        workerRegistry: WorkerRegistry
    ) async -> HivelinkToolCallResult {
        guard let worker = workerRegistry.resolve(query: query) else {
            return .textOnly("No worker found matching '\(query)'")
        }
        guard let task = taskService.tasks.first(where: { $0.id == worker.id }) else {
            return .textOnly("Task not found for \(worker.displayName)")
        }
        guard task.status == .planReview else {
            return .textOnly("Cannot approve plan — \(worker.displayName) is not in plan review (status: \(task.status.displayName)).")
        }

        await taskService.executePlan(for: task)
        let result = "Plan approved — \(worker.displayName) is now executing."
        let record = ToolUseRecord(
            toolName: "approve_plan",
            summary: "Approved plan for \(worker.displayName)",
            detail: result,
            fileResults: []
        )
        return HivelinkToolCallResult(text: result, transcriptRecord: record)
    }

    private static func handleRejectPlan(
        query: String,
        taskService: HivelinkTaskService,
        workerRegistry: WorkerRegistry
    ) async -> HivelinkToolCallResult {
        guard let worker = workerRegistry.resolve(query: query) else {
            return .textOnly("No worker found matching '\(query)'")
        }
        guard let task = taskService.tasks.first(where: { $0.id == worker.id }) else {
            return .textOnly("Task not found for \(worker.displayName)")
        }
        guard task.status == .planReview else {
            return .textOnly("Cannot reject plan — \(worker.displayName) is not in plan review (status: \(task.status.displayName)).")
        }

        await taskService.cancelPlanning(for: task)
        workerRegistry.deregister(taskId: worker.id)
        let result = "Plan rejected — \(worker.displayName) has been cancelled."
        let record = ToolUseRecord(
            toolName: "reject_plan",
            summary: "Rejected plan for \(worker.displayName)",
            detail: result,
            fileResults: []
        )
        return HivelinkToolCallResult(text: result, transcriptRecord: record)
    }

    // MARK: - Writeback Approval

    private static func handleApproveWriteback(
        query: String,
        taskService: HivelinkTaskService,
        workerRegistry: WorkerRegistry
    ) async -> HivelinkToolCallResult {
        guard let worker = workerRegistry.resolve(query: query) else {
            return .textOnly("No worker found matching '\(query)'")
        }
        guard let task = taskService.tasks.first(where: { $0.id == worker.id }) else {
            return .textOnly("Task not found for \(worker.displayName)")
        }
        guard task.status == .writebackReview else {
            return .textOnly("Cannot approve writeback — \(worker.displayName) is not in writeback review (status: \(task.status.displayName)).")
        }

        await taskService.approveWriteback(for: task)
        let count = task.pendingWritebackOperations.count
        let result = "Writeback approved — \(count) file\(count == 1 ? "" : "s") written to disk for \(worker.displayName)."
        let record = ToolUseRecord(
            toolName: "approve_writeback",
            summary: "Approved writeback for \(worker.displayName)",
            detail: result,
            fileResults: []
        )
        return HivelinkToolCallResult(text: result, transcriptRecord: record)
    }

    private static func handleDiscardWriteback(
        query: String,
        taskService: HivelinkTaskService,
        workerRegistry: WorkerRegistry
    ) async -> HivelinkToolCallResult {
        guard let worker = workerRegistry.resolve(query: query) else {
            return .textOnly("No worker found matching '\(query)'")
        }
        guard let task = taskService.tasks.first(where: { $0.id == worker.id }) else {
            return .textOnly("Task not found for \(worker.displayName)")
        }
        guard task.status == .writebackReview else {
            return .textOnly("Cannot discard writeback — \(worker.displayName) is not in writeback review (status: \(task.status.displayName)).")
        }

        await taskService.discardWriteback(for: task)
        let result = "Writeback discarded for \(worker.displayName) — no files were written."
        let record = ToolUseRecord(
            toolName: "discard_writeback",
            summary: "Discarded writeback for \(worker.displayName)",
            detail: result,
            fileResults: []
        )
        return HivelinkToolCallResult(text: result, transcriptRecord: record)
    }

    // MARK: - Capture Reference

    private static func handleCaptureReference(
        cameraCapture: CameraCaptureManager,
        orchestrator: HivelinkVoiceOrchestrator
    ) async -> HivelinkToolCallResult {
        guard orchestrator.supportsVideoInput else {
            return .textOnly("Error: The selected voice provider does not support realtime image or video input.")
        }

        let data: Data?
        let sourceName: String

        switch orchestrator.activeInputSource {
        case .camera:
            guard cameraCapture.isCapturing else {
                return .textOnly("Error: Camera is selected but not active yet. Wait a moment and try again.")
            }
            data = cameraCapture.captureStillFrame()
            sourceName = "camera"
        case .screenBroadcast:
            data = orchestrator.broadcastReceiver.latestFrameData
            sourceName = "screen broadcast"
        case .none:
            return .textOnly("Error: No video source active. Ask the user to enable the camera or screen broadcast via the input source picker.")
        }

        guard let data, !data.isEmpty else {
            return .textOnly("Error: No frame available from \(sourceName) yet — wait a moment and try again.")
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture_\(UUID().uuidString).jpg")
        do {
            try data.write(to: tempURL)
            let sizeKB = data.count / 1024
            let result = "Reference captured from \(sourceName) (\(sizeKB) KB): \(tempURL.path)"
            let record = ToolUseRecord(
                toolName: "capture_reference",
                summary: "Captured reference from \(sourceName) (\(sizeKB) KB)",
                detail: result,
                fileResults: [],
                previewFilePath: tempURL.path
            )
            return HivelinkToolCallResult(text: result, transcriptRecord: record)
        } catch {
            return .textOnly("Error: Failed to save capture to disk: \(error.localizedDescription)")
        }
    }

    // MARK: - Get Deliverables

    private static func handleGetDeliverables(
        query: String,
        taskService: HivelinkTaskService,
        workerRegistry: WorkerRegistry
    ) -> HivelinkToolCallResult {
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
            return HivelinkToolCallResult(text: result, transcriptRecord: record)
        }
        let result = "Deliverables from \(worker.displayName):\n" + files.joined(separator: "\n")
        let record = ToolUseRecord(
            toolName: "get_deliverables",
            summary: "Listed \(files.count) deliverable\(files.count == 1 ? "" : "s") from \(worker.displayName)",
            detail: result,
            fileResults: []
        )
        return HivelinkToolCallResult(text: result, transcriptRecord: record)
    }

    // MARK: - Focus Task

    private static func handleFocusTask(
        query: String,
        workerRegistry: WorkerRegistry,
        orchestrator: HivelinkVoiceOrchestrator
    ) -> HivelinkToolCallResult {
        guard let worker = workerRegistry.resolve(query: query) else {
            return .textOnly("No worker found matching '\(query)'")
        }
        orchestrator.focusedTaskId = worker.id
        NotificationCenter.default.post(name: .voiceFocusTask, object: nil, userInfo: ["taskId": worker.id])
        let result = "Focused on \(worker.displayName)"
        let record = ToolUseRecord(
            toolName: "focus_task",
            summary: result,
            detail: result,
            fileResults: []
        )
        return HivelinkToolCallResult(text: result, transcriptRecord: record)
    }

    // MARK: - End Call

    private static func handleEndCall(
        taskService: HivelinkTaskService,
        orchestrator: HivelinkVoiceOrchestrator
    ) -> HivelinkToolCallResult {
        orchestrator.endCallAfterSpeaking()

        let sessionTasks = taskService.tasks.filter { orchestrator.relevantTaskIds.contains($0.id) }
        let activeTasks = sessionTasks.filter { $0.status.isActive }
        let result: String
        if activeTasks.isEmpty {
            result = ""
        } else {
            let names = activeTasks.compactMap {
                orchestrator.workerRegistry.resolve(query: $0.id)?.displayName ?? $0.id
            }.joined(separator: ", ")
            result = "\(activeTasks.count) task(s) still running (\(names)) — they will continue in the background."
        }
        let record = ToolUseRecord(
            toolName: "end_call",
            summary: "Ending call",
            detail: result,
            fileResults: []
        )
        return HivelinkToolCallResult(text: result, transcriptRecord: record)
    }

    // MARK: - Read File

    private static func handleReadFile(path: String) async -> HivelinkToolCallResult {
        guard !path.isEmpty else {
            return .textOnly("Error: path is required for read_file.")
        }

        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            return .textOnly("Error: File not found at \(path)")
        }

        let filename = url.lastPathComponent
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        let sizeStr = ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)

        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"]
        if imageExtensions.contains(url.pathExtension.lowercased()) {
            let jpegData = imageAsJPEG(at: url)
            let text = "Image file: \(filename) (\(sizeStr)). The image has been loaded into your visual input."
            let record = ToolUseRecord(
                toolName: "read_file",
                summary: "Read \(filename) (\(sizeStr))",
                detail: text,
                fileResults: [],
                previewFilePath: path
            )
            return HivelinkToolCallResult(text: text, transcriptRecord: record, imageData: jpegData)
        }

        do {
            var text = try String(contentsOf: url, encoding: .utf8)
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
            return HivelinkToolCallResult(text: text, transcriptRecord: record)
        } catch {
            return .textOnly("Error reading file: \(error.localizedDescription)")
        }
    }

    private static func imageAsJPEG(at url: URL) -> Data? {
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }

        let maxDim: CGFloat = 1024
        let size = image.size
        if size.width > maxDim || size.height > maxDim {
            let scale = min(maxDim / size.width, maxDim / size.height)
            let newSize = CGSize(width: size.width * scale, height: size.height * scale)
            let renderer = UIGraphicsImageRenderer(size: newSize)
            let resized = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: newSize))
            }
            return resized.jpegData(compressionQuality: 0.8)
        }
        return image.jpegData(compressionQuality: 0.8)
    }

    // MARK: - Schema Conversion

    private static func fromSharedToolSchemas() -> [VoiceToolDeclaration] {
        SharedToolDeclarations.declarations.compactMap { schema -> VoiceToolDeclaration? in
            guard let name = schema["name"] as? String,
                  let description = schema["description"] as? String else { return nil }

            guard let paramsDict = schema["parameters"] as? [String: Any] else {
                return VoiceToolDeclaration(name: name, description: description, parameters: nil)
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
            return VoiceToolDeclaration(name: name, description: description, parameters: parameters)
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let voiceFocusTask = Notification.Name("voiceFocusTask")
}
