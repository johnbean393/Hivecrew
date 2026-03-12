//
//  ToolExecutor.swift
//  Hivecrew
//
//  Maps LLM tool calls to GuestAgentConnection methods
//

import Foundation
import SwiftData
import HivecrewLLM
import HivecrewShared

/// Executes tool calls from the LLM using the GuestAgentConnection
@MainActor
class ToolExecutor {
    let connection: GuestAgentConnection
    
    var taskId: String = ""
    var vmId: String = ""
    var onAskQuestion: ((AgentQuestion) async -> String)?
    var onRequestPermission: ((String, String) async -> Bool)?
    
    /// Callback when a todo item is finished (provides 1-based index and item text)
    var onTodoItemFinished: ((Int, String) -> Void)?
    
    /// Callback when a todo item is added (provides item text)
    var onTodoItemAdded: ((String) -> Void)?

    /// Callback when the todo list is created or updated
    var onTodoListUpdated: ((TodoList) -> Void)?
    
    let todoManager: TodoManager
    let taskProviderId: String
    let taskModelId: String
    weak var taskService: (any CreateWorkerClientProtocol)?
    let modelContext: ModelContext?
    weak var subagentManager: SubagentManager?
    let supportsVision: Bool

    private var concreteTaskService: TaskService? {
        taskService as? TaskService
    }
    
    init(
        connection: GuestAgentConnection,
        todoManager: TodoManager,
        taskProviderId: String,
        taskModelId: String,
        taskService: (any CreateWorkerClientProtocol)?,
        modelContext: ModelContext?,
        vmId: String,
        supportsVision: Bool
    ) {
        self.connection = connection
        self.todoManager = todoManager
        self.taskProviderId = taskProviderId
        self.taskModelId = taskModelId
        self.taskService = taskService
        self.modelContext = modelContext
        self.vmId = vmId
        self.supportsVision = supportsVision
    }
    
    func execute(toolCall: LLMToolCall) async -> ToolExecutionResult {
        let startTime = Date()
        let rawToolName = toolCall.function.name
        let toolName = canonicalToolName(rawToolName)
        if rawToolName != toolName {
            print("ToolExecutor: normalized tool name '\(rawToolName)' -> '\(toolName)'")
        }
        
        do {
            let args = try toolCall.function.argumentsDictionary()
            let result = try await executeToolInternal(name: toolName, args: args, toolCallId: toolCall.id)
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            
            switch result {
            case .text(let content):
                return .success(toolCallId: toolCall.id, toolName: toolName, result: content, durationMs: durationMs)
            case .image(let description, let base64, let mimeType):
                return .successWithImage(toolCallId: toolCall.id, toolName: toolName, result: description, durationMs: durationMs, imageBase64: base64, imageMimeType: mimeType)
            }
        } catch {
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            return .failure(toolCallId: toolCall.id, toolName: toolName, error: error.localizedDescription, durationMs: durationMs)
        }
    }

    // MARK: - Tool Name Normalization
    
    private func canonicalToolName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let filteredScalars = trimmed.unicodeScalars.filter { scalar in
            if CharacterSet.controlCharacters.contains(scalar) {
                return false
            }
            if scalar.properties.generalCategory == .format {
                return false // zero-width and other formatting chars
            }
            return true
        }
        
        // Normalize to lowercase and replace separators/punctuation with underscores
        var normalized = ""
        var lastWasUnderscore = false
        let allowed = CharacterSet.alphanumerics
        for scalar in filteredScalars {
            if allowed.contains(scalar) {
                normalized.unicodeScalars.append(scalar)
                lastWasUnderscore = false
            } else if scalar.value == 95 { // underscore
                if !lastWasUnderscore {
                    normalized.append("_")
                    lastWasUnderscore = true
                }
            } else {
                if !lastWasUnderscore {
                    normalized.append("_")
                    lastWasUnderscore = true
                }
            }
        }
        normalized = normalized.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        
        // Handle common alias variations
        switch normalized {
        case "runshell":
            return "run_shell"
        case "spawnsubagent", "spawn_sub_agent":
            return "spawn_subagent"
        case "getsubagentstatus", "get_sub_agent_status":
            return "get_subagent_status"
        case "awaitsubagent", "await_subagent", "await_sub_agent", "awaitsubagents", "await_sub_agents":
            return "await_subagents"
        case "cancelsubagent", "cancel_sub_agent":
            return "cancel_subagent"
        case "listsubagents", "list_sub_agents":
            return "list_subagents"
        case "createtodolist", "create_to_do_list":
            return "create_todo_list"
        case "addtodoitem", "add_to_do_item":
            return "add_todo_item"
        case "finishtodoitem", "finish_to_do_item":
            return "finish_todo_item"
        case "sendmessage", "send_msg":
            return "send_message"
        default:
            return normalized
        }
    }
    
    private func executeToolInternal(name: String, args: [String: Any], toolCallId: String) async throws -> InternalToolResult {
        switch name {
        case "traverse_accessibility_tree":
            let pid = (args["pid"] as? Int).map { Int32($0) }
            let onlyVisibleElements = args["onlyVisibleElements"] as? Bool ?? true
            let result = try await connection.traverseAccessibilityTree(pid: pid, onlyVisibleElements: onlyVisibleElements)
            return .text("Traversed accessibility tree for \(result.appName): \(result.elements.count) elements found")
            
        case "open_app":
            let bundleId = args["bundleId"] as? String
            let appName = args["appName"] as? String
            try await connection.openApp(bundleId: bundleId, appName: appName)
            return .text("Opened app: \(appName ?? bundleId ?? "unknown")")
            
        case "open_file":
            let path = args["path"] as? String ?? ""
            try await connection.openFile(path: path, withApp: args["withApp"] as? String)
            return .text("Opened file: \(path)")
            
        case "open_url":
            let url = args["url"] as? String ?? ""
            try await connection.openUrl(url)
            return .text("Opened URL: \(url)")
            
        case "mouse_move":
            let x = parseDouble(args["x"]), y = parseDouble(args["y"])
            try await connection.mouseMove(x: x, y: y)
            return .text("Moved mouse to (\(Int(x)), \(Int(y)))")
            
        case "mouse_click":
            let x = parseDouble(args["x"]), y = parseDouble(args["y"])
            let button = args["button"] as? String ?? "left"
            let clickType = args["clickType"] as? String ?? "single"
            try await connection.mouseClick(x: x, y: y, button: button, clickType: clickType)
            return .text("Clicked at (\(Int(x)), \(Int(y))) with \(button) button")
            
        case "mouse_drag":
            let fromX = parseDouble(args["fromX"]), fromY = parseDouble(args["fromY"])
            let toX = parseDouble(args["toX"]), toY = parseDouble(args["toY"])
            try await connection.mouseDrag(fromX: fromX, fromY: fromY, toX: toX, toY: toY)
            return .text("Dragged from (\(Int(fromX)), \(Int(fromY))) to (\(Int(toX)), \(Int(toY)))")
            
        case "keyboard_type":
            let originalText = args["text"] as? String ?? ""
            let actualText = CredentialManager.shared.substituteTokens(in: originalText)
            // Debug: check if substitution happened
            if originalText != actualText {
                print("ToolExecutor: keyboard_type - token substitution performed (original contained credential token)")
            } else if originalText.contains("-") && originalText.count == 36 {
                // Looks like a UUID that wasn't substituted
                print("ToolExecutor: keyboard_type - WARNING: text looks like UUID but was NOT substituted. tokenMap may be missing this token.")
                print("ToolExecutor: tokenMap has \(CredentialManager.shared.credentials.count) credentials loaded")
            }
            try await connection.keyboardType(text: actualText)
            return .text("Typed: \"\(originalText.prefix(50))\(originalText.count > 50 ? "..." : "")\"")
            
        case "keyboard_key":
            let key = args["key"] as? String ?? ""
            let modifiers = args["modifiers"] as? [String] ?? []
            try await connection.keyboardKey(key: key, modifiers: modifiers)
            let modStr = modifiers.isEmpty ? "" : "\(modifiers.joined(separator: "+"))+"
            return .text("Pressed key: \(modStr)\(key)")
            
        case "scroll":
            let x = parseDouble(args["x"]), y = parseDouble(args["y"])
            let deltaX = parseDouble(args["deltaX"]), deltaY = parseDouble(args["deltaY"])
            try await connection.scroll(x: x, y: y, deltaX: -deltaX, deltaY: -deltaY)
            return .text("Scrolled at (\(Int(x)), \(Int(y)))")
            
        case "run_shell":
            return try await executeShellCommand(args: args)
            
        case "read_file":
            let path = args["path"] as? String ?? ""
            let result = try await connection.readFile(path: path)
            switch result {
            case .text(let content, _): return .text(content)
            case .image(let base64, let mimeType, let w, let h):
                var desc = "Image file read successfully"
                if let w = w, let h = h { desc += " (\(w)x\(h) pixels)" }
                if supportsVision {
                    return .image(description: desc, base64: base64, mimeType: mimeType)
                }
                return .text("\(desc). Image content omitted because the active model does not support vision input.")
            }

        case "write_file":
            return try await executeWriteFile(args: args)

        case "list_directory":
            return try await executeListDirectory(args: args)
            
        case "move_file":
            let source = args["source"] as? String ?? ""
            let destination = args["destination"] as? String ?? ""
            try await connection.moveFile(source: source, destination: destination)
            return .text("Moved '\(source)' to '\(destination)'")
            
        case "wait":
            let seconds = parseDouble(args["seconds"], default: 1.0)
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return .text("Waited \(seconds) seconds")
            
        case "ask_text_question":
            return try await executeAskTextQuestion(args: args, toolCallId: toolCallId)
            
        case "ask_multiple_choice":
            return try await executeAskMultipleChoice(args: args, toolCallId: toolCallId)
            
        case "request_user_intervention":
            return try await executeRequestIntervention(args: args, toolCallId: toolCallId)
            
        case "get_login_credentials":
            return executeGetCredentials(args: args)
            
        case "web_search":
            return try await executeWebSearchTool(args: args)
            
        case "read_webpage_content":
            return try await executeReadWebpageContent(args: args)
            
        case "extract_info_from_webpage":
            return try await executeExtractInfoFromWebpage(args: args, taskProviderId: taskProviderId, taskModelId: taskModelId, taskService: taskService)
            
        case "get_location":
            return try await executeGetLocation()
            
        case "create_todo_list":
            return executeCreateTodoList(args: args)
            
        case "add_todo_item":
            return try executeAddTodoItem(args: args)
            
        case "finish_todo_item":
            return try executeFinishTodoItem(args: args)
            
        case "generate_image":
            return try await executeGenerateImage(args: args)

        case "list_local_entries":
            return try executeListLocalEntries(args: args)

        case "import_local_file":
            return try await executeImportLocalFile(args: args)

        case "stage_writeback_copy":
            return try await executeStageWriteback(args: args, operationType: .copy)

        case "stage_writeback_move":
            return try await executeStageWriteback(args: args, operationType: .move)

        case "stage_attached_file_update":
            return try await executeStageAttachedFileUpdate(args: args)

        case "list_writeback_targets":
            return try executeListWritebackTargets()
            
        case "spawn_subagent":
            return await executeSpawnSubagent(args: args)
            
        case "get_subagent_status":
            return await executeGetSubagentStatus(args: args)
            
        case "await_subagents", "await_subagent":
            return await executeAwaitSubagents(args: args)
            
        case "cancel_subagent":
            return await executeCancelSubagent(args: args)
            
        case "list_subagents":
            return await executeListSubagents()
            
        case "send_message":
            return await executeSendMessage(args: args, from: "main")
            
        default:
            // Check if this is an MCP tool
            if isMCPTool(name) {
                return try await executeMCPTool(name: name, args: args)
            }
            throw ToolExecutorError.unknownTool(name)
        }
    }
    
    // MARK: - Shell Command
    
    private func executeShellCommand(args: [String: Any]) async throws -> InternalToolResult {
        let command = args["command"] as? String ?? ""
        let timeout = parseDoubleOptional(args["timeout"])
        
        if UserDefaults.standard.bool(forKey: "requireConfirmationForShell") {
            let approved = await onRequestPermission?("Shell Command", command) ?? false
            if !approved { return .text("Command blocked: User denied permission") }
        }
        
        let result = try await connection.runShell(command: command, timeout: timeout)
        var output = "Exit code: \(result.exitCode)"
        if !result.stdout.isEmpty { output += "\nstdout: \(result.stdout.prefix(500))" }
        if !result.stderr.isEmpty { output += "\nstderr: \(result.stderr.prefix(500))" }
        return .text(output)
    }

    private func executeWriteFile(args: [String: Any]) async throws -> InternalToolResult {
        let path = args["path"] as? String ?? ""
        let contents = args["contents"] as? String ?? ""
        let base64Contents = Data(contents.utf8).base64EncodedString()
        let quotedPath = shellSingleQuoted(path)
        let quotedBase64 = shellSingleQuoted(base64Contents)

        let command = """
            mkdir -p "$(dirname \(quotedPath))" && \
            printf '%s' \(quotedBase64) | /usr/bin/base64 -D > \(quotedPath)
            """

        let result = try await connection.runShell(command: command, timeout: 20)
        guard result.exitCode == 0 else {
            throw ToolExecutorError.executionFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        return .text("Wrote \(contents.count) bytes to '\(path)'")
    }

    private func executeListDirectory(args: [String: Any]) async throws -> InternalToolResult {
        let path = args["path"] as? String ?? ""
        let quotedPath = shellSingleQuoted(path)

        let command = """
            TARGET=\(quotedPath); export TARGET; /usr/bin/python3 - <<'PY'
            import json
            import os
            import stat
            import time
            path = os.environ["TARGET"]
            entries = []
            with os.scandir(path) as iterator:
                for entry in sorted(iterator, key=lambda item: item.name.lower()):
                    info = entry.stat(follow_symlinks=False)
                    entries.append({
                        "name": entry.name,
                        "isDirectory": entry.is_dir(follow_symlinks=False),
                        "size": info.st_size,
                        "modifiedAt": int(info.st_mtime)
                    })
            print(json.dumps(entries, indent=2))
            PY
            """

        let result = try await connection.runShell(command: command, timeout: 20)
        guard result.exitCode == 0 else {
            throw ToolExecutorError.executionFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        return .text(result.stdout)
    }

    private func executeStageWriteback(args: [String: Any], operationType: WritebackOperationType) async throws -> InternalToolResult {
        guard let taskService = concreteTaskService else {
            throw ToolExecutorError.executionFailed("Writeback staging requires TaskService.")
        }
        guard let task = taskService.tasks.first(where: { $0.id == taskId }),
              let sessionId = task.sessionId else {
            throw WritebackStagingError.missingSession
        }
        let deleteOriginalLocalPaths = (args["deleteOriginalLocalPaths"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if operationType == .copy {
            let sourcePaths = (args["sourcePaths"] as? [String] ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !sourcePaths.isEmpty {
                let destinationDirectory = (args["destinationDirectory"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !destinationDirectory.isEmpty else {
                    throw ToolExecutorError.executionFailed("destinationDirectory is required when staging multiple writeback sources.")
                }
                return try await stageWritebackSources(
                    sourcePaths,
                    toDestinationDirectory: destinationDirectory,
                    deleteOriginalLocalPaths: deleteOriginalLocalPaths,
                    taskId: task.id,
                    sessionId: sessionId,
                    taskService: taskService
                )
            }
        }

        let sourcePath = (args["sourcePath"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let destinationPath = (args["destinationPath"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourcePath.isEmpty, !destinationPath.isEmpty else {
            throw ToolExecutorError.executionFailed("Provide sourcePath and destinationPath for a single writeback stage.")
        }

        let operation = try await stageSingleWriteback(
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            operationType: operationType,
            deleteOriginalLocalPaths: deleteOriginalLocalPaths,
            taskId: task.id,
            sessionId: sessionId,
            taskService: taskService
        )

        let deleteSuffix = operation.deleteOriginalTargets.isEmpty
            ? ""
            : " and will remove \(operation.deleteOriginalTargets.count) original local item(s) on apply"
        return .text("Staged \(operation.operationType.rawValue) to '\(operation.destinationPath)'\(deleteSuffix)")
    }

    private func executeStageAttachedFileUpdate(args: [String: Any]) async throws -> InternalToolResult {
        guard let taskService = concreteTaskService else {
            throw ToolExecutorError.executionFailed("Writeback staging requires TaskService.")
        }
        guard let task = taskService.tasks.first(where: { $0.id == taskId }),
              let sessionId = task.sessionId else {
            throw WritebackStagingError.missingSession
        }

        let sourcePath = args["sourcePath"] as? String ?? ""
        let attachmentPath = args["attachmentPath"] as? String
        let snapshotURL = try await snapshotVMSourceEntry(at: sourcePath)
        defer { try? FileManager.default.removeItem(at: snapshotURL.deletingLastPathComponent()) }

        let operation = try taskService.stageAttachedFileUpdate(
            taskId: task.id,
            sessionId: sessionId,
            snapshotURL: snapshotURL,
            vmSourcePath: sourcePath,
            attachmentOriginalPath: attachmentPath
        )

        return .text("Staged update for '\(operation.destinationPath)'")
    }

    private func executeListWritebackTargets() throws -> InternalToolResult {
        guard let taskService = concreteTaskService else {
            throw ToolExecutorError.executionFailed("Writeback staging requires TaskService.")
        }
        let targets = try taskService.listWritebackTargets(taskId: taskId)
        if targets.isEmpty {
            return .text("No local writeback targets are currently granted.")
        }

        let lines = targets.map { target in
            let kind = target.scopeKind == .folder ? "folder" : "file"
            return "- \(target.displayName) (\(kind)): \(target.rootPath)"
        }
        return .text("Granted writeback targets:\n" + lines.joined(separator: "\n"))
    }

    private func executeListLocalEntries(args: [String: Any]) throws -> InternalToolResult {
        guard let taskService = concreteTaskService else {
            throw ToolExecutorError.executionFailed("Local filesystem access requires TaskService.")
        }
        guard let task = taskService.tasks.first(where: { $0.id == taskId }) else {
            throw ToolExecutorError.executionFailed("Task '\(taskId)' was not found.")
        }

        let path = args["path"] as? String ?? ""
        guard !path.isEmpty else {
            throw ToolExecutorError.executionFailed("A host path is required.")
        }

        let grant = try requireLocalGrant(for: path, task: task)
        let targetURL = URL(fileURLWithPath: path).standardizedFileURL
        let fileManager = FileManager.default

        return try withScopedLocalAccess(for: grant) {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: targetURL.path, isDirectory: &isDirectory) else {
                throw ToolExecutorError.executionFailed("Host path '\(targetURL.path)' does not exist.")
            }

            if isDirectory.boolValue {
                let entries = try fileManager.contentsOfDirectory(
                    at: targetURL,
                    includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                )
                let lines = entries.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
                    .map { entry in
                        let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                        let kind = values?.isDirectory == true ? "folder" : "file"
                        let size = values?.fileSize.map(String.init) ?? "-"
                        return "- \(entry.lastPathComponent) (\(kind), size: \(size)): \(entry.path)"
                    }
                return .text(lines.isEmpty ? "Host folder is empty: \(targetURL.path)" : "Host entries for \(targetURL.path):\n" + lines.joined(separator: "\n"))
            } else {
                let attributes = try fileManager.attributesOfItem(atPath: targetURL.path)
                let size = attributes[.size] as? NSNumber
                return .text("Host file: \(targetURL.path)\nsize: \(size?.stringValue ?? "-") bytes")
            }
        }
    }

    private func executeImportLocalFile(args: [String: Any]) async throws -> InternalToolResult {
        guard let taskService = concreteTaskService else {
            throw ToolExecutorError.executionFailed("Local filesystem access requires TaskService.")
        }
        guard let task = taskService.tasks.first(where: { $0.id == taskId }) else {
            throw ToolExecutorError.executionFailed("Task '\(taskId)' was not found.")
        }

        let sourcePaths = (args["sourcePaths"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !sourcePaths.isEmpty {
            let destinationDirectory = (args["destinationDirectory"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !destinationDirectory.isEmpty else {
                throw ToolExecutorError.executionFailed("destinationDirectory is required when importing multiple sources.")
            }
            return try await importLocalSources(sourcePaths, toDirectoryInVM: destinationDirectory, task: task)
        }

        let sourcePath = (args["sourcePath"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let destinationPath = (args["destinationPath"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourcePath.isEmpty, !destinationPath.isEmpty else {
            throw ToolExecutorError.executionFailed("Provide sourcePath and destinationPath for a single import, or sourcePaths and destinationDirectory for a batch import.")
        }

        return try await importSingleLocalSource(sourcePath, toPathInVM: destinationPath, task: task)
    }

    private func importSingleLocalSource(
        _ sourcePath: String,
        toPathInVM destinationPath: String,
        task: TaskRecord
    ) async throws -> InternalToolResult {
        let sourceURL = URL(fileURLWithPath: sourcePath).standardizedFileURL
        let grant = try requireLocalGrant(for: sourceURL.path, task: task)
        let stagingToken = UUID().uuidString
        let hostStagingDirectory = AppPaths.vmWorkspaceDirectory(id: vmId)
            .appendingPathComponent(".hivecrew-local-imports", isDirectory: true)
            .appendingPathComponent(stagingToken, isDirectory: true)

        try FileManager.default.createDirectory(at: hostStagingDirectory, withIntermediateDirectories: true)
        let stagedHostURL = hostStagingDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        defer {
            try? FileManager.default.removeItem(at: hostStagingDirectory)
        }

        let isDirectory = try withScopedLocalAccess(for: grant) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
                throw ToolExecutorError.executionFailed("Host path '\(sourceURL.path)' does not exist.")
            }
            if FileManager.default.fileExists(atPath: stagedHostURL.path) {
                try FileManager.default.removeItem(at: stagedHostURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: stagedHostURL)
            return isDirectory.boolValue
        }

        let guestSourcePath = "/Volumes/Shared/workspace/.hivecrew-local-imports/\(stagingToken)/\(sourceURL.lastPathComponent)"
        let command: String
        if isDirectory {
            command = """
                mkdir -p "$(dirname \(shellSingleQuoted(destinationPath)))" && \
                cp -R \(shellSingleQuoted(guestSourcePath)) \(shellSingleQuoted(destinationPath))
                """
        } else {
            command = """
                mkdir -p "$(dirname \(shellSingleQuoted(destinationPath)))" && \
                cp -f \(shellSingleQuoted(guestSourcePath)) \(shellSingleQuoted(destinationPath))
                """
        }
        let result = try await connection.runShell(command: command, timeout: 20)
        guard result.exitCode == 0 else {
            throw ToolExecutorError.executionFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }

        let kind = isDirectory ? "directory" : "file"
        return .text("Imported host \(kind) '\(sourceURL.path)' to VM path '\(destinationPath)'")
    }

    private func importLocalSources(
        _ sourcePaths: [String],
        toDirectoryInVM destinationDirectory: String,
        task: TaskRecord
    ) async throws -> InternalToolResult {
        let sourceURLs = sourcePaths.map { URL(fileURLWithPath: $0).standardizedFileURL }
        let stagingToken = UUID().uuidString
        let hostStagingDirectory = AppPaths.vmWorkspaceDirectory(id: vmId)
            .appendingPathComponent(".hivecrew-local-imports", isDirectory: true)
            .appendingPathComponent(stagingToken, isDirectory: true)

        try FileManager.default.createDirectory(at: hostStagingDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: hostStagingDirectory)
        }

        for sourceURL in sourceURLs {
            let grant = try requireLocalGrant(for: sourceURL.path, task: task)
            try withScopedLocalAccess(for: grant) {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
                    throw ToolExecutorError.executionFailed("Host path '\(sourceURL.path)' does not exist.")
                }

                let stagedHostURL = uniqueImportedStagingURL(
                    in: hostStagingDirectory,
                    preferredName: sourceURL.lastPathComponent
                )
                try FileManager.default.copyItem(at: sourceURL, to: stagedHostURL)
            }
        }

        let guestStagingDirectory = "/Volumes/Shared/workspace/.hivecrew-local-imports/\(stagingToken)"
        let command = """
            mkdir -p \(shellSingleQuoted(destinationDirectory)) && \
            cp -R \(shellSingleQuoted(guestStagingDirectory))/. \(shellSingleQuoted(destinationDirectory))/
            """
        let result = try await connection.runShell(command: command, timeout: 60)
        guard result.exitCode == 0 else {
            throw ToolExecutorError.executionFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }

        return .text("Imported \(sourceURLs.count) host entr\(sourceURLs.count == 1 ? "y" : "ies") to VM directory '\(destinationDirectory)'")
    }

    private func stageSingleWriteback(
        sourcePath: String,
        destinationPath: String,
        operationType: WritebackOperationType,
        deleteOriginalLocalPaths: [String],
        taskId: String,
        sessionId: String,
        taskService: TaskService
    ) async throws -> PendingWritebackOperation {
        let snapshotURL = try await snapshotVMSourceEntry(at: sourcePath)
        defer { try? FileManager.default.removeItem(at: snapshotURL.deletingLastPathComponent()) }

        return try taskService.stageWritebackOperation(
            taskId: taskId,
            sessionId: sessionId,
            snapshotURL: snapshotURL,
            vmSourcePath: sourcePath,
            destinationPath: destinationPath,
            operationType: operationType,
            deleteOriginalPaths: deleteOriginalLocalPaths
        )
    }

    private func stageWritebackSources(
        _ sourcePaths: [String],
        toDestinationDirectory destinationDirectory: String,
        deleteOriginalLocalPaths: [String],
        taskId: String,
        sessionId: String,
        taskService: TaskService
    ) async throws -> InternalToolResult {
        var stagedDestinations: [String] = []
        for (index, sourcePath) in sourcePaths.enumerated() {
            let sourceURL = URL(fileURLWithPath: sourcePath)
            let destinationPath = URL(fileURLWithPath: destinationDirectory)
                .appendingPathComponent(sourceURL.lastPathComponent)
                .path
            let operation = try await stageSingleWriteback(
                sourcePath: sourcePath,
                destinationPath: destinationPath,
                operationType: .copy,
                deleteOriginalLocalPaths: index == 0 ? deleteOriginalLocalPaths : [],
                taskId: taskId,
                sessionId: sessionId,
                taskService: taskService
            )
            stagedDestinations.append(operation.destinationPath)
        }

        let deleteSuffix = deleteOriginalLocalPaths.isEmpty
            ? ""
            : " and will remove \(deleteOriginalLocalPaths.count) original local item(s) on apply"
        return .text("Staged \(stagedDestinations.count) VM entr\(stagedDestinations.count == 1 ? "y" : "ies") for copy into '\(destinationDirectory)'\(deleteSuffix)")
    }

    private func snapshotVMSourceEntry(at sourcePath: String) async throws -> URL {
        let token = UUID().uuidString
        let fileName = URL(fileURLWithPath: sourcePath).lastPathComponent
        let quotedSource = shellSingleQuoted(sourcePath)
        let guestStagingDirectory = "/Volumes/Shared/workspace/.hivecrew-writeback-staging/\(token)"
        let guestStagingPath = "\(guestStagingDirectory)/\(fileName)"
        let quotedGuestStagingPath = shellSingleQuoted(guestStagingPath)

        let command = """
            test -e \(quotedSource) && \
            mkdir -p \(shellSingleQuoted(guestStagingDirectory)) && \
            cp -R \(quotedSource) \(quotedGuestStagingPath) && \
            sync
            """

        let result = try await connection.runShell(command: command, timeout: 20)
        guard result.exitCode == 0 else {
            throw ToolExecutorError.executionFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }

        let hostStagingDirectory = AppPaths.vmWorkspaceDirectory(id: vmId)
            .appendingPathComponent(".hivecrew-writeback-staging", isDirectory: true)
            .appendingPathComponent(token, isDirectory: true)
        let hostSnapshotURL = hostStagingDirectory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: hostSnapshotURL.path) else {
            throw ToolExecutorError.executionFailed("Failed to snapshot '\(sourcePath)' from the VM.")
        }
        return hostSnapshotURL
    }

    private func shellSingleQuoted(_ string: String) -> String {
        "'\(string.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func uniqueImportedStagingURL(in directory: URL, preferredName: String) -> URL {
        let candidate = directory.appendingPathComponent(preferredName)
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            return candidate
        }

        let suffix = UUID().uuidString.prefix(8)
        let ext = (preferredName as NSString).pathExtension
        let base = (preferredName as NSString).deletingPathExtension
        let uniqueName = ext.isEmpty ? "\(base)-\(suffix)" : "\(base)-\(suffix).\(ext)"
        return directory.appendingPathComponent(uniqueName)
    }

    private func requireLocalGrant(for path: String, task: TaskRecord) throws -> LocalAccessGrant {
        guard let grant = task.localAccessGrants.first(where: { $0.allowsAccess(to: path) }) else {
            throw ToolExecutorError.executionFailed("No granted local filesystem access allows '\(path)'.")
        }
        return grant
    }

    private func withScopedLocalAccess<T>(for grant: LocalAccessGrant, body: () throws -> T) throws -> T {
        if let bookmarkData = grant.bookmarkData {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            return try body()
        }
        return try body()
    }
    
    // MARK: - Question Tools
    
    private func executeAskTextQuestion(args: [String: Any], toolCallId: String) async throws -> InternalToolResult {
        let question = args["question"] as? String ?? ""
        guard let callback = onAskQuestion else { return .text("Error: No question handler") }
        let q = AgentTextQuestion(id: toolCallId, taskId: taskId, question: question)
        let answer = await callback(.text(q))
        return .text("User answered: \(answer)")
    }
    
    private func executeAskMultipleChoice(args: [String: Any], toolCallId: String) async throws -> InternalToolResult {
        let question = args["question"] as? String ?? ""
        let options = args["options"] as? [String] ?? []
        guard let callback = onAskQuestion else { return .text("Error: No question handler") }
        let q = AgentMultipleChoiceQuestion(id: toolCallId, taskId: taskId, question: question, options: options)
        let answer = await callback(.multipleChoice(q))
        return .text("User selected: \(answer)")
    }
    
    private func executeRequestIntervention(args: [String: Any], toolCallId: String) async throws -> InternalToolResult {
        let message = args["message"] as? String ?? ""
        let service = args["service"] as? String
        guard let callback = onAskQuestion else { return .text("Error: No handler") }
        let request = AgentInterventionRequest(id: toolCallId, taskId: taskId, message: message, service: service)
        let response = await callback(.intervention(request))
        return .text(response == "completed" ? "User completed the requested action" : "User cancelled")
    }
    
    // MARK: - Credential Tools
    
    private func executeGetCredentials(args: [String: Any]) -> InternalToolResult {
        let serviceFilter = args["service"] as? String
        
        var credentials = CredentialManager.shared.getCredentialsForAgent(service: serviceFilter)
        
        var noMatchMsg: String? = nil
        
        if credentials.isEmpty, let service = serviceFilter {
            credentials = CredentialManager.shared.getCredentialsForAgent(service: nil)
            if !credentials.isEmpty { noMatchMsg = "No credentials matching '\(service)'. Returning all." }
        }
        
        if credentials.isEmpty {
            return .text("No credentials stored.")
        }
        
        var output = noMatchMsg.map { "\($0)\n\n" } ?? ""
        output += "Available credentials:\n\n"
        for cred in credentials {
            // Get the actual username to display (not tokenized since usernames aren't sensitive)
            let usernameDisplay = CredentialManager.shared.resolveToken(cred.usernameToken.uuidString) ?? "(no username)"
            // Use explicit .uuidString for password token to ensure consistent format for substitution
            output += "\(cred.displayName):\n  Username: \(usernameDisplay)\n  Password: \(cred.passwordToken.uuidString)\n\n"
        }
        return .text(output)
    }
    
    // MARK: - Todo Tools
    
    private func executeCreateTodoList(args: [String: Any]) -> InternalToolResult {
        let title = args["title"] as? String ?? "Untitled"
        let items = args["items"] as? [String]
        let list = todoManager.createList(title: title, items: items)
        onTodoListUpdated?(list)
        var result = "✓ Created: \(list.title)\n"
        for (i, item) in list.items.enumerated() {
            result += "\(i+1). \(item.isCompleted ? "[✓]" : "[ ]") \(item.text)\n"
        }
        return .text(result)
    }
    
    private func executeAddTodoItem(args: [String: Any]) throws -> InternalToolResult {
        let itemText = args["item"] as? String ?? ""
        let index = try todoManager.addItem(itemText: itemText)
        
        // Notify callback for plan state sync
        onTodoItemAdded?(itemText)
        if let list = todoManager.getList() {
            onTodoListUpdated?(list)
        }
        
        return .text("✓ Added item #\(index): \(itemText)")
    }
    
    private func executeFinishTodoItem(args: [String: Any]) throws -> InternalToolResult {
        let index = args["index"] as? Int ?? 0
        
        // Get the item text before finishing (for plan state sync)
        var itemText = ""
        if let list = todoManager.getList(), index >= 1 && index <= list.items.count {
            itemText = list.items[index - 1].text
        }
        
        try todoManager.finishItem(index: index)
        
        // Notify callback for plan state sync
        onTodoItemFinished?(index, itemText)
        if let list = todoManager.getList() {
            onTodoListUpdated?(list)
        }
        
        return .text("✓ Marked item #\(index) as completed")
    }
    
    // MARK: - Subagent Tools
    
    private func executeSpawnSubagent(args: [String: Any]) async -> InternalToolResult {
        guard let manager = subagentManager else {
            return .text("Error: Subagent manager not available")
        }
        
        let goal = args["goal"] as? String ?? ""
        let purpose = args["purpose"] as? String
        let domainRaw = args["domain"] as? String ?? "host"
        var domain = SubagentDomain(rawValue: domainRaw) ?? .host
        let researchGoal = isResearchGoal(goal)
        let needsFileIO = requiresFileIO(goal)
        if researchGoal && domain == .vm {
            // Research should run with host tools; allow mixed if file output is required.
            domain = needsFileIO ? .mixed : .host
        }
        if needsFileIO && domain == .host {
            // File output requires VM tools (run_shell/read_file) alongside host tools.
            domain = .mixed
        }
        
        let toolAllowlist = (args["toolAllowlist"] as? [String]) ?? (args["tool_allowlist"] as? [String])
        let todoItemsRaw = (args["todoItems"] as? [String]) ?? (args["todo_items"] as? [String]) ?? []
        let todoItems = todoItemsRaw
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if todoItems.isEmpty {
            return .text("Error: todoItems is required when spawning subagents. Provide a concise main-agent-prescribed todo list.")
        }
        let timeoutSeconds = parseDoubleOptional(args["timeoutSeconds"] ?? args["timeout_seconds"])

        let info = await manager.spawn(
            goal: goal,
            domain: domain,
            toolAllowlist: toolAllowlist,
            todoItems: todoItems,
            timeoutSeconds: timeoutSeconds,
            purpose: purpose
        )
        
        var output = "Subagent spawned: \(info.id)"
        if let purpose = info.purpose, !purpose.isEmpty {
            output += "\nPurpose: \(purpose)"
        }
        output += "\nDomain: \(info.domain.rawValue)"
        if domainRaw != domain.rawValue {
            if researchGoal && needsFileIO {
                output += "\nNote: Domain adjusted to \(info.domain.rawValue) for research plus file output."
            } else if researchGoal {
                output += "\nNote: Domain adjusted to \(info.domain.rawValue) for research."
            } else if needsFileIO {
                output += "\nNote: Domain adjusted to \(info.domain.rawValue) to allow file output tools."
            }
        }
        output += "\nStatus: \(info.status.rawValue)"
        return .text(output)
    }
    
    private func executeGetSubagentStatus(args: [String: Any]) async -> InternalToolResult {
        guard let manager = subagentManager else {
            return .text("Error: Subagent manager not available")
        }
        let id = args["subagentId"] as? String ?? ""
        guard let info = manager.getStatus(subagentId: id) else {
            return .text("Subagent not found: \(id)")
        }
        return .text(formatSubagentInfo(info))
    }
    
    private func executeAwaitSubagents(args: [String: Any]) async -> InternalToolResult {
        guard let manager = subagentManager else {
            return .text("Error: Subagent manager not available")
        }
        let ids = parseSubagentIds(args)
        if ids.isEmpty {
            return .text("Error: subagentIds is required")
        }
        let timeoutSeconds = parseDoubleOptional(args["timeoutSeconds"] ?? args["timeout_seconds"]) ?? 600
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        
        var notFound: Set<String> = []
        var pending: [String] = []
        for id in ids {
            if manager.getStatus(subagentId: id) == nil {
                notFound.insert(id)
            } else {
                pending.append(id)
            }
        }
        
        var resultsById: [String: SubagentManager.Info] = [:]
        if !pending.isEmpty {
            await withTaskGroup(of: (String, SubagentManager.Info?).self) { group in
                for id in pending {
                    group.addTask { [manager] in
                        let remaining = deadline.timeIntervalSinceNow
                        if remaining <= 0 {
                            return (id, nil)
                        }
                        let info = await manager.awaitResult(subagentId: id, timeoutSeconds: remaining)
                        return (id, info)
                    }
                }
                
                for await (id, info) in group {
                    if let info {
                        resultsById[id] = info
                    }
                }
            }
        }
        
        var outputBlocks: [String] = []
        for id in ids {
            if notFound.contains(id) {
                outputBlocks.append("Subagent not found: \(id)")
                continue
            }
            if let info = resultsById[id] {
                outputBlocks.append(formatSubagentInfo(info))
                continue
            }
            outputBlocks.append("Timed out waiting for subagent \(id)")
        }
        
        return .text(outputBlocks.joined(separator: "\n\n"))
    }
    
    private func executeCancelSubagent(args: [String: Any]) async -> InternalToolResult {
        guard let manager = subagentManager else {
            return .text("Error: Subagent manager not available")
        }
        let id = args["subagentId"] as? String ?? ""
        let cancelled = await manager.cancel(subagentId: id)
        return .text(cancelled ? "Cancelled subagent \(id)" : "Subagent not found: \(id)")
    }
    
    private func executeListSubagents() async -> InternalToolResult {
        guard let manager = subagentManager else {
            return .text("Error: Subagent manager not available")
        }
        let infos = manager.list()
        if infos.isEmpty {
            return .text("No subagents")
        }
        let lines = infos.map { formatSubagentInfo($0) }
        return .text(lines.joined(separator: "\n\n"))
    }
    
    private func executeSendMessage(args: [String: Any], from: String) async -> InternalToolResult {
        guard let manager = subagentManager else {
            return .text("Error: Subagent manager not available")
        }
        let to = args["to"] as? String ?? ""
        let subject = args["subject"] as? String ?? ""
        let body = args["body"] as? String ?? ""
        
        if to.isEmpty {
            return .text("Error: 'to' is required (use 'main', a subagent ID, or 'broadcast').")
        }
        
        manager.sendMessage(from: from, to: to, subject: subject, body: body)
        
        let recipientLabel = to == "main" ? "main agent" : (to == "broadcast" ? "all agents" : "subagent \(to)")
        return .text("Message sent to \(recipientLabel). Subject: \(subject)")
    }
    
    private func formatSubagentInfo(_ info: SubagentManager.Info) -> String {
        var lines: [String] = []
        lines.append("ID: \(info.id)")
        if let purpose = info.purpose, !purpose.isEmpty {
            lines.append("Purpose: \(purpose)")
        }
        lines.append("Domain: \(info.domain.rawValue)")
        lines.append("Status: \(info.status.rawValue)")
        if let summary = info.summary, !summary.isEmpty {
            lines.append("Summary: \(summary)")
        }
        if let error = info.errorMessage, !error.isEmpty {
            lines.append("Error: \(error)")
        }
        return lines.joined(separator: "\n")
    }
    
    private func parseSubagentIds(_ args: [String: Any]) -> [String] {
        if let ids = args["subagentIds"] as? [String] {
            return ids.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        if let ids = args["subagent_ids"] as? [String] {
            return ids.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        if let id = args["subagentId"] as? String {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }
        if let id = args["subagent_id"] as? String {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }
        if let idsString = args["subagentIds"] as? String {
            let parts = idsString.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            return parts.filter { !$0.isEmpty }
        }
        return []
    }
    
    private func parseDoubleOptional(_ value: Any?) -> Double? {
        if let v = value as? Double { return v }
        if let v = value as? Int { return Double(v) }
        if let v = value as? String, let d = Double(v) { return d }
        return nil
    }
    
    private func isResearchGoal(_ goal: String) -> Bool {
        let lowered = goal.lowercased()
        return lowered.contains("research") ||
        lowered.contains("latest") ||
        lowered.contains("compare") ||
        lowered.contains("benchmark") ||
        lowered.contains("pricing") ||
        lowered.contains("release date") ||
        lowered.contains("llm") ||
        lowered.contains("model")
    }
    
    private func requiresFileIO(_ goal: String) -> Bool {
        let lowered = goal.lowercased()
        if lowered.contains("outbox") || lowered.contains("inbox") || lowered.contains("workspace") {
            return true
        }
        if lowered.contains("~/") || lowered.contains("/desktop/") || lowered.contains("/documents/") {
            return true
        }
        let extensions = [
            ".md", ".txt", ".pdf", ".doc", ".docx", ".ppt", ".pptx", ".key",
            ".csv", ".json", ".rtf", ".html", ".png", ".jpg", ".jpeg", ".gif", ".webp"
        ]
        return extensions.contains(where: { lowered.contains($0) })
    }
}
