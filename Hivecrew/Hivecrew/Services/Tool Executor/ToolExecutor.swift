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
    
    let todoManager: TodoManager
    let taskProviderId: String
    let taskModelId: String
    weak var taskService: (any CreateWorkerClientProtocol)?
    let modelContext: ModelContext?
    
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
        let toolName = toolCall.function.name
        
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
            
        default:
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
        var result = "✓ Created: \(list.title)\n"
        for (i, item) in list.items.enumerated() {
            result += "\(i+1). \(item.isCompleted ? "[✓]" : "[ ]") \(item.text)\n"
        }
        return .text(result)
    }
    
    private func executeAddTodoItem(args: [String: Any]) throws -> InternalToolResult {
        let itemText = args["item"] as? String ?? ""
        let index = try todoManager.addItem(itemText: itemText)
        return .text("✓ Added item #\(index): \(itemText)")
    }
    
    private func executeFinishTodoItem(args: [String: Any]) throws -> InternalToolResult {
        let index = args["index"] as? Int ?? 0
        try todoManager.finishItem(index: index)
        return .text("✓ Marked item #\(index) as completed")
    }
}
