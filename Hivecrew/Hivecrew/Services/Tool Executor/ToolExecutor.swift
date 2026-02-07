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
    
    init(
        connection: GuestAgentConnection,
        todoManager: TodoManager,
        taskProviderId: String,
        taskModelId: String,
        taskService: (any CreateWorkerClientProtocol)?,
        modelContext: ModelContext?,
        vmId: String
    ) {
        self.connection = connection
        self.todoManager = todoManager
        self.taskProviderId = taskProviderId
        self.taskModelId = taskModelId
        self.taskService = taskService
        self.modelContext = modelContext
        self.vmId = vmId
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
                return .image(description: desc, base64: base64, mimeType: mimeType)
            }
            
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
        print("ToolExecutor: get_login_credentials called with service filter: \(serviceFilter ?? "nil")")
        
        var credentials = CredentialManager.shared.getCredentialsForAgent(service: serviceFilter)
        print("ToolExecutor: getCredentialsForAgent returned \(credentials.count) credentials")
        
        var noMatchMsg: String? = nil
        
        if credentials.isEmpty, let service = serviceFilter {
            credentials = CredentialManager.shared.getCredentialsForAgent(service: nil)
            if !credentials.isEmpty { noMatchMsg = "No credentials matching '\(service)'. Returning all." }
        }
        
        if credentials.isEmpty {
            print("ToolExecutor: No credentials found, returning empty message")
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
        print("ToolExecutor: get_login_credentials returning output (\(output.count) chars):\n\(output)")
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
        let modelOverride = args["modelOverride"] as? String ?? args["model_override"] as? String
        
        let info = await manager.spawn(
            goal: goal,
            domain: domain,
            toolAllowlist: toolAllowlist,
            todoItems: todoItems,
            timeoutSeconds: timeoutSeconds,
            modelOverride: modelOverride,
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
        if lowered.contains("outbox") || lowered.contains("inbox") {
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
