//
//  ToolExecutor.swift
//  Hivecrew
//
//  Maps LLM tool calls to GuestAgentConnection methods
//

import Foundation
import HivecrewLLM
import GoogleSearch

/// Result of a tool execution
struct ToolExecutionResult: Sendable {
    let toolCallId: String
    let toolName: String
    let success: Bool
    let result: String
    let errorMessage: String?
    let durationMs: Int
    
    static func success(toolCallId: String, toolName: String, result: String, durationMs: Int) -> ToolExecutionResult {
        ToolExecutionResult(
            toolCallId: toolCallId,
            toolName: toolName,
            success: true,
            result: result,
            errorMessage: nil,
            durationMs: durationMs
        )
    }
    
    static func failure(toolCallId: String, toolName: String, error: String, durationMs: Int) -> ToolExecutionResult {
        ToolExecutionResult(
            toolCallId: toolCallId,
            toolName: toolName,
            success: false,
            result: "",
            errorMessage: error,
            durationMs: durationMs
        )
    }
}

/// Executes tool calls from the LLM using the GuestAgentConnection
@MainActor
class ToolExecutor {
    private let connection: GuestAgentConnection
    
    /// Task ID for associating questions with tasks
    var taskId: String = ""
    
    /// Callback for when the agent asks a question
    var onAskQuestion: ((AgentQuestion) async -> String)?
    
    /// Callback for requesting permission to execute dangerous tools
    /// Parameters: (toolName, details) -> approved
    var onRequestPermission: ((String, String) async -> Bool)?
    
    /// Todo manager for tracking agent tasks
    private let todoManager: TodoManager
    
    /// Task provider ID for worker model fallback
    private let taskProviderId: String
    
    /// Task model ID for worker model fallback
    private let taskModelId: String
    
    /// Task service for creating worker LLM clients
    private weak var taskService: (any CreateWorkerClientProtocol)?
    
    init(
        connection: GuestAgentConnection,
        todoManager: TodoManager,
        taskProviderId: String,
        taskModelId: String,
        taskService: (any CreateWorkerClientProtocol)?
    ) {
        self.connection = connection
        self.todoManager = todoManager
        self.taskProviderId = taskProviderId
        self.taskModelId = taskModelId
        self.taskService = taskService
    }
    
    /// Execute a tool call and return the result
    func execute(toolCall: LLMToolCall) async -> ToolExecutionResult {
        let startTime = Date()
        let toolName = toolCall.function.name
        
        do {
            let args = try toolCall.function.argumentsDictionary()
            let result = try await executeToolInternal(name: toolName, args: args, toolCallId: toolCall.id)
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            return .success(toolCallId: toolCall.id, toolName: toolName, result: result, durationMs: durationMs)
        } catch {
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            return .failure(toolCallId: toolCall.id, toolName: toolName, error: error.localizedDescription, durationMs: durationMs)
        }
    }
    
    // MARK: - Private
    
    private func executeToolInternal(name: String, args: [String: Any], toolCallId: String) async throws -> String {
        switch name {
        // Observation tools
        case "screenshot":
            let result = try await connection.screenshot()
            return "Screenshot captured: \(result.width)x\(result.height) pixels"
            
        case "get_frontmost_app":
            let result = try await connection.getFrontmostApp()
            return "Frontmost app: \(result.appName ?? "Unknown") (\(result.bundleId ?? "unknown"))"
            
        case "traverse_accessibility_tree":
            let pid = (args["pid"] as? Int).map { Int32($0) }
            let onlyVisibleElements = args["onlyVisibleElements"] as? Bool ?? true
            let result = try await connection.traverseAccessibilityTree(pid: pid, onlyVisibleElements: onlyVisibleElements)
            return "Traversed accessibility tree for \(result.appName): \(result.elements.count) elements found in \(result.processingTimeSeconds)s"
            
        // App tools
        case "open_app":
            let bundleId = args["bundleId"] as? String
            let appName = args["appName"] as? String
            try await connection.openApp(bundleId: bundleId, appName: appName)
            return "Opened app: \(appName ?? bundleId ?? "unknown")"
            
        case "open_file":
            let path = args["path"] as? String ?? ""
            let withApp = args["withApp"] as? String
            try await connection.openFile(path: path, withApp: withApp)
            return "Opened file: \(path)"
            
        case "open_url":
            let url = args["url"] as? String ?? ""
            try await connection.openUrl(url)
            return "Opened URL: \(url)"
            
        // Input tools
        case "mouse_move":
            let x = parseDouble(args["x"])
            let y = parseDouble(args["y"])
            try await connection.mouseMove(x: x, y: y)
            return "Moved mouse to (\(Int(x)), \(Int(y)))"
            
        case "mouse_click":
            let x = parseDouble(args["x"])
            let y = parseDouble(args["y"])
            let button = args["button"] as? String ?? "left"
            let clickType = args["clickType"] as? String ?? "single"
            try await connection.mouseClick(x: x, y: y, button: button, clickType: clickType)
            return "Clicked at (\(Int(x)), \(Int(y))) with \(button) button (\(clickType))"
            
        case "mouse_drag":
            let fromX = parseDouble(args["fromX"])
            let fromY = parseDouble(args["fromY"])
            let toX = parseDouble(args["toX"])
            let toY = parseDouble(args["toY"])
            try await connection.mouseDrag(fromX: fromX, fromY: fromY, toX: toX, toY: toY)
            return "Dragged from (\(Int(fromX)), \(Int(fromY))) to (\(Int(toX)), \(Int(toY)))"
            
        case "keyboard_type":
            let text = args["text"] as? String ?? ""
            try await connection.keyboardType(text: text)
            return "Typed: \"\(text.prefix(50))\(text.count > 50 ? "..." : "")\""
            
        case "keyboard_key":
            let key = args["key"] as? String ?? ""
            let modifiers = args["modifiers"] as? [String] ?? []
            try await connection.keyboardKey(key: key, modifiers: modifiers)
            let modStr = modifiers.isEmpty ? "" : "\(modifiers.joined(separator: "+"))+"
            return "Pressed key: \(modStr)\(key)"
            
        case "scroll":
            let x = parseDouble(args["x"])
            let y = parseDouble(args["y"])
            let deltaX = parseDouble(args["deltaX"])
            let deltaY = parseDouble(args["deltaY"])
            // Invert scroll direction: positive deltaY from LLM means "scroll down" (see content below),
            // but CGEvent scroll wheel uses the opposite convention
            try await connection.scroll(x: x, y: y, deltaX: -deltaX, deltaY: -deltaY)
            return "Scrolled at (\(Int(x)), \(Int(y))) by (\(Int(deltaX)), \(Int(deltaY)))"
            
        // Shell tool
        case "run_shell":
            let command = args["command"] as? String ?? ""
            let timeout = parseDoubleOptional(args["timeout"])
            
            // Check if shell confirmation is required
            if UserDefaults.standard.bool(forKey: "requireConfirmationForShell") {
                let approved = await onRequestPermission?("Shell Command", command) ?? false
                if !approved {
                    return "Command blocked: User denied permission to execute shell command"
                }
            }
            
            let result = try await connection.runShell(command: command, timeout: timeout)
            var output = "Exit code: \(result.exitCode)"
            if !result.stdout.isEmpty {
                output += "\nstdout: \(result.stdout.prefix(500))"
            }
            if !result.stderr.isEmpty {
                output += "\nstderr: \(result.stderr.prefix(500))"
            }
            return output
            
        // File tools
        case "read_file":
            let path = args["path"] as? String ?? ""
            let result = try await connection.readFile(path: path)
            return result
            
        // System tools
        case "wait":
            let seconds = parseDouble(args["seconds"], default: 1.0)
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return "Waited \(seconds) seconds"
            
        case "health_check":
            let result = try await connection.healthCheck()
            return "Health check: \(result.status), Accessibility: \(result.accessibilityPermission), Screen Recording: \(result.screenRecordingPermission)"
            
        // Question tools
        case "ask_text_question":
            let question = args["question"] as? String ?? ""
            if let callback = onAskQuestion {
                let q = AgentTextQuestion(id: toolCallId, taskId: taskId, question: question)
                let answer = await callback(.text(q))
                return "User answered: \(answer)"
            } else {
                return "Error: No question handler available"
            }
            
        case "ask_multiple_choice":
            let question = args["question"] as? String ?? ""
            let options = args["options"] as? [String] ?? []
            if let callback = onAskQuestion {
                let q = AgentMultipleChoiceQuestion(id: toolCallId, taskId: taskId, question: question, options: options)
                let answer = await callback(.multipleChoice(q))
                return "User selected: \(answer)"
            } else {
                return "Error: No question handler available"
            }
            
        // Web tools
        case "web_search":
            let query = args["query"] as? String ?? ""
            let site = args["site"] as? String
            let resultCount = (args["resultCount"] as? Int) ?? 10
            let startDateStr = args["startDate"] as? String
            let endDateStr = args["endDate"] as? String
            
            // Parse dates if provided
            var startDate: Date?
            var endDate: Date?
            if let startDateStr = startDateStr {
                startDate = ISO8601DateFormatter().date(from: startDateStr)
            }
            if let endDateStr = endDateStr {
                endDate = ISO8601DateFormatter().date(from: endDateStr)
            }
            
            // Get search engine preference
            let searchEngine = UserDefaults.standard.string(forKey: "searchEngine") ?? "google"
            
            let results: [SearchResult]
            if searchEngine == "duckduckgo" {
                results = try await DuckDuckGoSearch.search(
                    query: query,
                    site: site,
                    resultCount: resultCount,
                    startDate: startDate,
                    endDate: endDate
                )
            } else {
                // Use GoogleSearch package
                let googleResults = try await GoogleSearch.search(
                    query: query,
                    site: site,
                    resultCount: resultCount,
                    startDate: startDate,
                    endDate: endDate
                )
                // Map GoogleSearch.SearchResult to our SearchResult type
                results = googleResults.map { googleResult in
                    SearchResult(
                        url: googleResult.source,
                        title: "Search Result",
                        snippet: googleResult.text
                    )
                }
            }
            
            // Format results
            var output = "Found \(results.count) results for '\(query)':\n\n"
            for (index, result) in results.enumerated() {
                output += "\(index + 1). \(result.title)\n"
                output += "   URL: \(result.url)\n"
                output += "   \(result.snippet)\n\n"
            }
            return output
            
        case "read_webpage_content":
            let urlString = args["url"] as? String ?? ""
            guard let url = URL(string: urlString) else {
                return "Error: Invalid URL format"
            }
            let content = try await WebpageReader.readWebpage(url: url)
            return content
            
        case "extract_info_from_webpage":
            let urlString = args["url"] as? String ?? ""
            let question = args["question"] as? String ?? ""
            guard let url = URL(string: urlString) else {
                return "Error: Invalid URL format"
            }
            guard let service = taskService else {
                return "Error: Task service not available"
            }
            let answer = try await WebpageExtractor.extractInfo(
                url: url,
                question: question,
                taskProviderId: self.taskProviderId,
                taskModelId: self.taskModelId,
                taskService: service
            )
            return answer
            
        case "get_location":
            let location = try await IPLocation.getLocation()
            return "Your location: \(location)"
            
        // Todo management tools
        case "create_todo_list":
            let title = args["title"] as? String ?? "Untitled"
            let items = args["items"] as? [String]
            let list = todoManager.createList(title: title, items: items)
            
            // Format the result with numbered items
            var result = "✓ Created todo list: \(list.title)\n\n"
            if list.items.isEmpty {
                result += "No items yet. Use add_todo_item to add tasks.\n"
            } else {
                result += "Items:\n"
                for (index, item) in list.items.enumerated() {
                    let number = index + 1
                    let status = item.isCompleted ? "[✓]" : "[ ]"
                    result += "\(number). \(status) \(item.text)\n"
                }
            }
            return result
            
        case "add_todo_item":
            let itemText = args["item"] as? String ?? ""
            let index = try todoManager.addItem(itemText: itemText)
            return "✓ Added item #\(index): \(itemText)"
            
        case "finish_todo_item":
            let index = args["index"] as? Int ?? 0
            try todoManager.finishItem(index: index)
            return "✓ Marked item #\(index) as completed"
            
        default:
            throw ToolExecutorError.unknownTool(name)
        }
    }
}

/// Errors from tool execution
enum ToolExecutorError: Error, LocalizedError {
    case unknownTool(String)
    case missingParameter(String)
    case executionFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .unknownTool(let name):
            return "Unknown tool: \(name)"
        case .missingParameter(let param):
            return "Missing required parameter: \(param)"
        case .executionFailed(let reason):
            return "Tool execution failed: \(reason)"
        }
    }
}

// MARK: - Number Parsing Helpers

/// Parse a numeric value that could be Int or Double from JSON
private func parseDouble(_ value: Any?, default defaultValue: Double = 0) -> Double {
    if let d = value as? Double { return d }
    if let i = value as? Int { return Double(i) }
    if let n = value as? NSNumber { return n.doubleValue }
    return defaultValue
}

/// Parse an optional numeric value that could be Int or Double from JSON
private func parseDoubleOptional(_ value: Any?) -> Double? {
    if value == nil { return nil }
    if let d = value as? Double { return d }
    if let i = value as? Int { return Double(i) }
    if let n = value as? NSNumber { return n.doubleValue }
    return nil
}
