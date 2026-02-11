//
//  SubagentToolExecutor.swift
//  Hivecrew
//
//  Executes tool calls for subagents with restricted capabilities.
//

import Foundation
import SwiftData
import GoogleSearch
import HivecrewLLM
import HivecrewMCP
import HivecrewShared

@MainActor
final class SubagentToolExecutor {
    enum ToolResult {
        case text(String)
        case image(description: String, base64: String, mimeType: String)
    }
    
    private let connection: GuestAgentConnection
    private let vmScheduler: VMToolScheduler
    private let vmId: String
    private let taskId: String
    private let taskProviderId: String
    private let taskModelId: String
    private weak var taskService: (any CreateWorkerClientProtocol)?
    private let todoManager: TodoManager
    private let modelContext: ModelContext?
    private var todoManagers: [String: TodoManager] = [:]
    private var subagentVisionSupport: [String: Bool] = [:]
    private let mainModelSupportsVision: Bool
    
    weak var subagentManager: SubagentManager?
    var onAskQuestion: ((AgentQuestion) async -> String)?
    var onRequestPermission: ((String, String) async -> Bool)?
    
    init(
        connection: GuestAgentConnection,
        vmScheduler: VMToolScheduler,
        vmId: String,
        taskId: String,
        taskProviderId: String,
        taskModelId: String,
        taskService: (any CreateWorkerClientProtocol)?,
        todoManager: TodoManager,
        modelContext: ModelContext?,
        mainModelSupportsVision: Bool
    ) {
        self.connection = connection
        self.vmScheduler = vmScheduler
        self.vmId = vmId
        self.taskId = taskId
        self.taskProviderId = taskProviderId
        self.taskModelId = taskModelId
        self.taskService = taskService
        self.todoManager = todoManager
        self.modelContext = modelContext
        self.mainModelSupportsVision = mainModelSupportsVision
    }
    
    func execute(toolCall: LLMToolCall, subagentId: String?) async throws -> ToolResult {
        let args = try toolCall.function.argumentsDictionary()
        let name = toolCall.function.name
        
        switch name {
        case "screenshot":
            return try await executeScreenshot()
        case "health_check":
            return try await executeHealthCheck()
        case "traverse_accessibility_tree":
            return try await executeTraverseAccessibilityTree(args: args)
        case "open_app":
            return try await executeOpenApp(args: args)
        case "open_file":
            return try await executeOpenFile(args: args)
        case "open_url":
            return try await executeOpenUrl(args: args)
        case "mouse_move":
            return try await executeMouseMove(args: args)
        case "mouse_click":
            return try await executeMouseClick(args: args)
        case "mouse_drag":
            return try await executeMouseDrag(args: args)
        case "keyboard_type":
            return try await executeKeyboardType(args: args)
        case "keyboard_key":
            return try await executeKeyboardKey(args: args)
        case "scroll":
            return try await executeScroll(args: args)
        case "run_shell":
            return try await executeRunShell(args: args)
        case "read_file":
            return try await executeReadFile(args: args, subagentId: subagentId)
        case "move_file":
            return try await executeMoveFile(args: args)
        case "wait":
            return try await executeWait(args: args)
        case "ask_text_question":
            return try await executeAskTextQuestion(args: args, toolCallId: toolCall.id)
        case "ask_multiple_choice":
            return try await executeAskMultipleChoice(args: args, toolCallId: toolCall.id)
        case "request_user_intervention":
            return try await executeRequestIntervention(args: args, toolCallId: toolCall.id)
        case "get_login_credentials":
            return executeGetCredentials(args: args)
        case "web_search":
            return try await executeWebSearch(args: args)
        case "read_webpage_content":
            return try await executeReadWebpageContent(args: args)
        case "extract_info_from_webpage":
            return try await executeExtractInfoFromWebpage(args: args)
        case "get_location":
            return try await executeGetLocation()
        case "create_todo_list":
            return try executeCreateTodoList(args: args, subagentId: subagentId)
        case "add_todo_item":
            return try executeAddTodoItem(args: args, subagentId: subagentId)
        case "finish_todo_item":
            return try executeFinishTodoItem(args: args, subagentId: subagentId)
        case "generate_image":
            return try await executeGenerateImage(args: args)
        case "send_message":
            return executeSendMessage(args: args, subagentId: subagentId)
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
        case SubagentRunner.finalReportToolName:
            // Handled by SubagentRunner directly; should not reach here.
            return .text("Error: \(SubagentRunner.finalReportToolName) must be handled by the runner, not the executor.")
        default:
            if MCPServerManager.shared.isMCPTool(name) {
                return try await executeMCPTool(name: name, args: args)
            }
            throw SubagentToolError.unknownTool(name)
        }
    }

    func registerTodoList(subagentId: String, title: String, items: [String]) {
        let manager = TodoManager()
        _ = manager.createList(title: title, items: items)
        todoManagers[subagentId] = manager
    }

    func registerVisionCapability(subagentId: String, supportsVision: Bool) {
        subagentVisionSupport[subagentId] = supportsVision
    }

    func clearTodoList(subagentId: String) {
        todoManagers.removeValue(forKey: subagentId)
        subagentVisionSupport.removeValue(forKey: subagentId)
    }
    
    // MARK: - VM Tools
    
    private func executeScreenshot() async throws -> ToolResult {
        let result = try await vmScheduler.run {
            try await self.connection.screenshot()
        }
        let desc = "Screenshot captured (\(result.width)x\(result.height) pixels)"
        return .image(description: desc, base64: result.imageBase64, mimeType: "image/png")
    }
    
    private func executeHealthCheck() async throws -> ToolResult {
        let result = try await vmScheduler.run {
            try await self.connection.healthCheck()
        }
        var output = "Status: \(result.status)"
        output += "\nAccessibility permission: \(result.accessibilityPermission ? "granted" : "missing")"
        output += "\nScreen recording permission: \(result.screenRecordingPermission ? "granted" : "missing")"
        output += "\nShared folder mounted: \(result.sharedFolderMounted ? "yes" : "no")"
        if let path = result.sharedFolderPath { output += "\nShared folder path: \(path)" }
        output += "\nAgent version: \(result.agentVersion)"
        return .text(output)
    }
    
    private func executeTraverseAccessibilityTree(args: [String: Any]) async throws -> ToolResult {
        let pid = (args["pid"] as? Int).map { Int32($0) }
        let onlyVisibleElements = args["onlyVisibleElements"] as? Bool ?? true
        let result = try await vmScheduler.run {
            try await self.connection.traverseAccessibilityTree(pid: pid, onlyVisibleElements: onlyVisibleElements)
        }
        return .text("Traversed accessibility tree for \(result.appName): \(result.elements.count) elements found")
    }
    
    private func executeOpenApp(args: [String: Any]) async throws -> ToolResult {
        let bundleId = args["bundleId"] as? String
        let appName = args["appName"] as? String
        try await vmScheduler.run {
            try await self.connection.openApp(bundleId: bundleId, appName: appName)
        }
        return .text("Opened app: \(appName ?? bundleId ?? "unknown")")
    }
    
    private func executeOpenFile(args: [String: Any]) async throws -> ToolResult {
        let path = args["path"] as? String ?? ""
        let withApp = args["withApp"] as? String
        try await vmScheduler.run {
            try await self.connection.openFile(path: path, withApp: withApp)
        }
        return .text("Opened file: \(path)")
    }
    
    private func executeOpenUrl(args: [String: Any]) async throws -> ToolResult {
        let url = args["url"] as? String ?? ""
        try await vmScheduler.run {
            try await self.connection.openUrl(url)
        }
        return .text("Opened URL: \(url)")
    }
    
    private func executeMouseMove(args: [String: Any]) async throws -> ToolResult {
        let x = parseDouble(args["x"])
        let y = parseDouble(args["y"])
        try await vmScheduler.run {
            try await self.connection.mouseMove(x: x, y: y)
        }
        return .text("Moved mouse to (\(Int(x)), \(Int(y)))")
    }
    
    private func executeMouseClick(args: [String: Any]) async throws -> ToolResult {
        let x = parseDouble(args["x"])
        let y = parseDouble(args["y"])
        let button = args["button"] as? String ?? "left"
        let clickType = args["clickType"] as? String ?? "single"
        try await vmScheduler.run {
            try await self.connection.mouseClick(x: x, y: y, button: button, clickType: clickType)
        }
        return .text("Clicked at (\(Int(x)), \(Int(y))) with \(button) button")
    }
    
    private func executeMouseDrag(args: [String: Any]) async throws -> ToolResult {
        let fromX = parseDouble(args["fromX"])
        let fromY = parseDouble(args["fromY"])
        let toX = parseDouble(args["toX"])
        let toY = parseDouble(args["toY"])
        try await vmScheduler.run {
            try await self.connection.mouseDrag(fromX: fromX, fromY: fromY, toX: toX, toY: toY)
        }
        return .text("Dragged from (\(Int(fromX)), \(Int(fromY))) to (\(Int(toX)), \(Int(toY)))")
    }
    
    private func executeKeyboardType(args: [String: Any]) async throws -> ToolResult {
        let originalText = args["text"] as? String ?? ""
        let actualText = CredentialManager.shared.substituteTokens(in: originalText)
        try await vmScheduler.run {
            try await self.connection.keyboardType(text: actualText)
        }
        let preview = originalText.prefix(50)
        return .text("Typed: \"\(preview)\(originalText.count > 50 ? "..." : "")\"")
    }
    
    private func executeKeyboardKey(args: [String: Any]) async throws -> ToolResult {
        let key = args["key"] as? String ?? ""
        let modifiers = args["modifiers"] as? [String] ?? []
        try await vmScheduler.run {
            try await self.connection.keyboardKey(key: key, modifiers: modifiers)
        }
        let modStr = modifiers.isEmpty ? "" : "\(modifiers.joined(separator: "+"))+"
        return .text("Pressed key: \(modStr)\(key)")
    }
    
    private func executeScroll(args: [String: Any]) async throws -> ToolResult {
        let x = parseDouble(args["x"])
        let y = parseDouble(args["y"])
        let deltaX = parseDouble(args["deltaX"])
        let deltaY = parseDouble(args["deltaY"])
        try await vmScheduler.run {
            try await self.connection.scroll(x: x, y: y, deltaX: -deltaX, deltaY: -deltaY)
        }
        return .text("Scrolled at (\(Int(x)), \(Int(y)))")
    }
    
    private func executeRunShell(args: [String: Any]) async throws -> ToolResult {
        let command = args["command"] as? String ?? ""
        let timeout = parseDoubleOptional(args["timeout"])
        
        if UserDefaults.standard.bool(forKey: "requireConfirmationForShell") {
            let approved = await onRequestPermission?("Shell Command", command) ?? false
            if !approved { return .text("Command blocked: User denied permission") }
        }
        
        let result = try await vmScheduler.run {
            try await self.connection.runShell(command: command, timeout: timeout)
        }
        var output = "Exit code: \(result.exitCode)"
        if !result.stdout.isEmpty { output += "\nstdout: \(result.stdout.prefix(2000))" }
        if !result.stderr.isEmpty { output += "\nstderr: \(result.stderr.prefix(2000))" }
        return .text(output)
    }
    
    private func executeReadFile(args: [String: Any], subagentId: String?) async throws -> ToolResult {
        let path = args["path"] as? String ?? ""
        let result = try await vmScheduler.run {
            try await self.connection.readFile(path: path)
        }
        switch result {
        case .text(let content, _):
            return .text(content)
        case .image(let base64, let mimeType, let w, let h):
            var desc = "Image file read successfully"
            if let w = w, let h = h { desc += " (\(w)x\(h) pixels)" }
            if supportsVision(for: subagentId) {
                return .image(description: desc, base64: base64, mimeType: mimeType)
            }
            return .text("\(desc). Image content omitted because the active model does not support vision input.")
        }
    }
    
    private func executeMoveFile(args: [String: Any]) async throws -> ToolResult {
        let source = args["source"] as? String ?? ""
        let destination = args["destination"] as? String ?? ""
        try await vmScheduler.run {
            try await self.connection.moveFile(source: source, destination: destination)
        }
        return .text("Moved file from \(source) to \(destination)")
    }
    
    private func executeWait(args: [String: Any]) async throws -> ToolResult {
        let seconds = parseDouble(args["seconds"], default: 1.0)
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        return .text("Waited \(seconds) seconds")
    }
    
    // MARK: - Question Tools
    
    private func executeAskTextQuestion(args: [String: Any], toolCallId: String) async throws -> ToolResult {
        let question = args["question"] as? String ?? ""
        guard let callback = onAskQuestion else { return .text("Error: No question handler") }
        let q = AgentTextQuestion(id: toolCallId, taskId: taskId, question: question)
        let answer = await callback(.text(q))
        return .text("User answered: \(answer)")
    }
    
    private func executeAskMultipleChoice(args: [String: Any], toolCallId: String) async throws -> ToolResult {
        let question = args["question"] as? String ?? ""
        let options = args["options"] as? [String] ?? []
        guard let callback = onAskQuestion else { return .text("Error: No question handler") }
        let q = AgentMultipleChoiceQuestion(id: toolCallId, taskId: taskId, question: question, options: options)
        let answer = await callback(.multipleChoice(q))
        return .text("User selected: \(answer)")
    }
    
    private func executeRequestIntervention(args: [String: Any], toolCallId: String) async throws -> ToolResult {
        let message = args["message"] as? String ?? ""
        let service = args["service"] as? String
        guard let callback = onAskQuestion else { return .text("Error: No handler") }
        let request = AgentInterventionRequest(id: toolCallId, taskId: taskId, message: message, service: service)
        let response = await callback(.intervention(request))
        return .text(response == "completed" ? "User completed the requested action" : "User cancelled")
    }
    
    // MARK: - Credential Tools
    
    private func executeGetCredentials(args: [String: Any]) -> ToolResult {
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
            let usernameDisplay = CredentialManager.shared.resolveToken(cred.usernameToken.uuidString) ?? "(no username)"
            output += "\(cred.displayName):\n  Username: \(usernameDisplay)\n  Password: \(cred.passwordToken.uuidString)\n\n"
        }
        
        return .text(output)
    }
    
    // MARK: - Host Tools
    
    private func executeWebSearch(args: [String: Any]) async throws -> ToolResult {
        let query = args["query"] as? String ?? ""
        let site = args["site"] as? String
        let resultCount = (args["resultCount"] as? Int) ?? 10
        let startDateStr = args["startDate"] as? String
        let endDateStr = args["endDate"] as? String
        
        var startDate: Date?
        var endDate: Date?
        if let startDateStr = startDateStr {
            startDate = ISO8601DateFormatter().date(from: startDateStr)
        }
        if let endDateStr = endDateStr {
            endDate = ISO8601DateFormatter().date(from: endDateStr)
        }
        
        let searchEngine = UserDefaults.standard.string(forKey: "searchEngine") ?? "google"
        let fallbackEngines = fallbackSearchEngines(for: searchEngine)
        var usedEngine = searchEngine
        var results: [SearchResult] = []
        var fallbackNotes: [String] = []
        
        let simplifiedQuery = simplifyQuery(query)
        var queryVariants = [query]
        if !simplifiedQuery.isEmpty, simplifiedQuery != query {
            queryVariants.append(simplifiedQuery)
        }
        
        func performSearch(engine: String, query: String, site: String?) async throws -> [SearchResult] {
            switch engine {
            case "duckduckgo":
                return try await DuckDuckGoSearch.search(
                    query: query,
                    site: site,
                    resultCount: resultCount,
                    startDate: startDate,
                    endDate: endDate
                )
            case "searchapi":
                guard let apiKey = SearchProviderKeychain.retrieveSearchAPIKey(), !apiKey.isEmpty else {
                    throw SearchProviderError.missingAPIKey("SearchAPI")
                }
                return try await SearchAPIClient.search(
                    query: query,
                    site: site,
                    resultCount: resultCount,
                    startDate: startDate,
                    endDate: endDate,
                    apiKey: apiKey
                )
            case "serpapi":
                guard let apiKey = SearchProviderKeychain.retrieveSerpAPIKey(), !apiKey.isEmpty else {
                    throw SearchProviderError.missingAPIKey("SerpAPI")
                }
                return try await SerpAPIClient.search(
                    query: query,
                    site: site,
                    resultCount: resultCount,
                    startDate: startDate,
                    endDate: endDate,
                    apiKey: apiKey
                )
            default:
                let googleResults = try await GoogleSearch.search(
                    query: query,
                    site: site,
                    resultCount: resultCount,
                    startDate: startDate,
                    endDate: endDate
                )
                return googleResults.map { googleResult in
                    SearchResult(
                        url: googleResult.source,
                        title: "Search Result",
                        snippet: googleResult.text
                    )
                }
            }
        }
        
        for variant in queryVariants {
            for engine in [searchEngine] + fallbackEngines {
                do {
                    results = try await performSearch(engine: engine, query: variant, site: site)
                    if !results.isEmpty {
                        usedEngine = engine
                        if engine != searchEngine {
                            fallbackNotes.append("Retried with \(engine).")
                        }
                        break
                    }
                } catch {
                    fallbackNotes.append("Search (\(engine)) failed: \(error.localizedDescription)")
                }
            }
            
            if results.isEmpty, site != nil {
                for engine in [usedEngine] + fallbackEngines {
                    do {
                        results = try await performSearch(engine: engine, query: variant, site: nil)
                        if !results.isEmpty {
                            if engine != usedEngine {
                                fallbackNotes.append("Broadened search used \(engine).")
                            }
                            fallbackNotes.append("No results with site filter; broadened search.")
                            break
                        }
                    } catch {
                        fallbackNotes.append("Broadened search (\(engine)) failed: \(error.localizedDescription)")
                    }
                }
            }
            
            if !results.isEmpty {
                if variant != query {
                    fallbackNotes.append("Used simplified query: \"\(variant)\".")
                }
                break
            }
        }
        
        var output = "Found \(results.count) results for '\(query)':\n\n"
        for (index, result) in results.enumerated() {
            output += "\(index + 1). \(result.title)\n"
            output += "   URL: \(result.url)\n"
            output += "   \(result.snippet)\n\n"
        }
        if !fallbackNotes.isEmpty {
            output += "Notes:\n" + fallbackNotes.joined(separator: "\n")
        }
        return .text(output)
    }
    
    private func simplifyQuery(_ query: String) -> String {
        var simplified = query
        let patterns = [
            "\\b(19|20)\\d{2}\\b",
            "\\b(as of|latest|current|recent)\\b",
            "\\b(release date|pricing|benchmark|benchmarks)\\b"
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(simplified.startIndex..., in: simplified)
                simplified = regex.stringByReplacingMatches(in: simplified, options: [], range: range, withTemplate: "")
            }
        }
        simplified = simplified.replacingOccurrences(of: "  ", with: " ")
        return simplified.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fallbackSearchEngines(for primary: String) -> [String] {
        switch primary {
        case "duckduckgo":
            return ["google"]
        case "searchapi", "serpapi":
            return ["google", "duckduckgo"]
        default:
            return ["duckduckgo"]
        }
    }
    
    private func executeReadWebpageContent(args: [String: Any]) async throws -> ToolResult {
        let urlString = args["url"] as? String ?? ""
        guard let url = URL(string: urlString) else {
            return .text("Error: Invalid URL format")
        }
        let content = try await WebpageReader.readWebpage(url: url)
        return .text(content)
    }
    
    private func executeExtractInfoFromWebpage(args: [String: Any]) async throws -> ToolResult {
        let urlString = args["url"] as? String ?? ""
        let question = args["question"] as? String ?? ""
        guard let url = URL(string: urlString) else {
            return .text("Error: Invalid URL format")
        }
        guard let service = taskService else {
            return .text("Error: Task service not available")
        }
        let answer = try await WebpageExtractor.extractInfo(
            url: url,
            question: question,
            taskProviderId: taskProviderId,
            taskModelId: taskModelId,
            taskService: service
        )
        return .text(answer)
    }
    
    private func executeGetLocation() async throws -> ToolResult {
        let location = try await IPLocation.getLocation()
        return .text("Your location: \(location)")
    }
    
    // MARK: - Todo Tools
    
    private func executeCreateTodoList(args: [String: Any], subagentId: String?) throws -> ToolResult {
        if subagentId != nil {
            return .text("Error: create_todo_list is disabled for subagents. Use the prescribed todo list.")
        }
        let title = args["title"] as? String ?? "Untitled"
        let items = args["items"] as? [String]
        let list = todoManager.createList(title: title, items: items)
        var result = "✓ Created: \(list.title)\n"
        for (i, item) in list.items.enumerated() {
            result += "\(i+1). \(item.isCompleted ? "[✓]" : "[ ]") \(item.text)\n"
        }
        return .text(result)
    }
    
    private func executeAddTodoItem(args: [String: Any], subagentId: String?) throws -> ToolResult {
        if subagentId != nil {
            return .text("Error: add_todo_item is disabled for subagents. Use the prescribed todo list.")
        }
        let itemText = args["item"] as? String ?? ""
        let index = try todoManager.addItem(itemText: itemText)
        return .text("✓ Added item #\(index): \(itemText)")
    }
    
    private func executeFinishTodoItem(args: [String: Any], subagentId: String?) throws -> ToolResult {
        let index = args["index"] as? Int ?? 0
        try todoManager(for: subagentId).finishItem(index: index)
        return .text("✓ Marked item #\(index) as completed")
    }
    
    // MARK: - Image Generation
    
    private func executeGenerateImage(args: [String: Any]) async throws -> ToolResult {
        let prompt = args["prompt"] as? String ?? ""
        let referenceImagePaths = args["referenceImagePaths"] as? [String]
        let aspectRatio = args["aspectRatio"] as? String
        
        guard let config = try await getImageGenerationConfig(aspectRatio: aspectRatio) else {
            return .text("Error: Image generation is not configured. Enable it in Settings > Tasks.")
        }
        
        let outputDirectory = AppPaths.vmInboxDirectory(id: vmId).appendingPathComponent("images", isDirectory: true)
        
        var referenceImages: [(data: String, mimeType: String)]?
        if let paths = referenceImagePaths, !paths.isEmpty {
            referenceImages = []
            for (index, path) in paths.enumerated() {
                if let imageData = try? await loadReferenceImage(path: path) {
                    if index == 0 {
                        if imageData.mimeType == "image/png" || imageData.mimeType == "image/jpeg" {
                            referenceImages?.append(imageData)
                        } else if let converted = ImageDownscaler.convertToJPEG(
                            base64Data: imageData.data,
                            mimeType: imageData.mimeType
                        ) {
                            referenceImages?.append(converted)
                        } else {
                            referenceImages?.append(imageData)
                        }
                    } else {
                        if let downscaled = ImageDownscaler.downscale(
                            base64Data: imageData.data,
                            mimeType: imageData.mimeType,
                            to: .small
                        ) {
                            referenceImages?.append(downscaled)
                        } else {
                            referenceImages?.append(imageData)
                        }
                    }
                }
            }
        }
        
        let service = ImageGenerationService(outputDirectory: outputDirectory)
        let result = try await service.generateImage(
            prompt: prompt,
            referenceImages: referenceImages,
            config: config
        )
        
        var response = "Image generated and saved to: \(result.imagePath)"
        if let description = result.description {
            response += "\n\nModel description: \(description)"
        }
        return .text(response)
    }
    
    private func getImageGenerationConfig(aspectRatio: String?) async throws -> ImageGenerationConfiguration? {
        guard let modelContext = self.modelContext else {
            return nil
        }
        
        ImageGenerationAvailability.autoConfigureIfNeeded(modelContext: modelContext)
        
        guard UserDefaults.standard.bool(forKey: "imageGenerationEnabled") else {
            return nil
        }
        
        let providerString = UserDefaults.standard.string(forKey: "imageGenerationProvider") ?? "openRouter"
        let provider = ImageGenerationProvider(rawValue: providerString) ?? .openRouter
        
        let configuredModel = (UserDefaults.standard.string(forKey: "imageGenerationModel") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let model = configuredModel.isEmpty
            ? ImageGenerationAvailability.defaultModel(for: provider)
            : configuredModel
        
        if configuredModel.isEmpty {
            UserDefaults.standard.set(model, forKey: "imageGenerationModel")
        }
        
        guard let (apiKey, baseURL) = ImageGenerationAvailability.getCredentials(modelContext: modelContext) else {
            return nil
        }
        
        return ImageGenerationConfiguration(
            provider: provider,
            model: model,
            apiKey: apiKey,
            baseURL: provider == .openRouter ? baseURL : nil,
            aspectRatio: aspectRatio
        )
    }
    
    private func loadReferenceImage(path: String) async throws -> (data: String, mimeType: String)? {
        let result = try await connection.readFile(path: path)
        
        switch result {
        case .image(let base64, let mimeType, _, _):
            return (base64, mimeType)
        case .text:
            return nil
        }
    }
    
    // MARK: - Messaging Tools
    
    private func executeSendMessage(args: [String: Any], subagentId: String?) -> ToolResult {
        guard let manager = subagentManager else {
            return .text("Error: Subagent manager not available")
        }
        let from = subagentId ?? "unknown"
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
    
    // MARK: - Subagent Tools
    
    private func executeSpawnSubagent(args: [String: Any]) async -> ToolResult {
        guard let manager = subagentManager else {
            return .text("Error: Subagent manager not available")
        }
        
        let goal = args["goal"] as? String ?? ""
        let purpose = args["purpose"] as? String
        let domainRaw = args["domain"] as? String ?? "host"
        let domain = SubagentDomain(rawValue: domainRaw) ?? .host
        
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
        output += "\nStatus: \(info.status.rawValue)"
        return .text(output)
    }
    
    private func executeGetSubagentStatus(args: [String: Any]) async -> ToolResult {
        guard let manager = subagentManager else {
            return .text("Error: Subagent manager not available")
        }
        let id = args["subagentId"] as? String ?? ""
        guard let info = manager.getStatus(subagentId: id) else {
            return .text("Subagent not found: \(id)")
        }
        return .text(formatSubagentInfo(info))
    }
    
    private func executeAwaitSubagents(args: [String: Any]) async -> ToolResult {
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
    
    private func executeCancelSubagent(args: [String: Any]) async -> ToolResult {
        guard let manager = subagentManager else {
            return .text("Error: Subagent manager not available")
        }
        let id = args["subagentId"] as? String ?? ""
        let cancelled = await manager.cancel(subagentId: id)
        return .text(cancelled ? "Cancelled subagent \(id)" : "Subagent not found: \(id)")
    }
    
    private func executeListSubagents() async -> ToolResult {
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
    
    // MARK: - MCP Tools
    
    private func executeMCPTool(name: String, args: [String: Any]) async throws -> ToolResult {
        await MCPServerManager.shared.connectAllEnabledIfNeeded()
        let result = try await MCPServerManager.shared.executeTool(name: name, arguments: args)
        
        if result.isError == true {
            return .text("Error: \(result.textContent)")
        }
        
        for content in result.content {
            if content.type == "image", let data = content.data, let mimeType = content.mimeType {
                return .image(
                    description: content.text ?? "Image from MCP tool",
                    base64: data,
                    mimeType: mimeType
                )
            }
        }
        
        let textContent = result.textContent
        if textContent.isEmpty {
            return .text("Tool executed successfully")
        }
        return .text(textContent)
    }
    
    // MARK: - Helpers
    
    private func parseDouble(_ value: Any?, default defaultValue: Double = 0) -> Double {
        if let v = value as? Double { return v }
        if let v = value as? Int { return Double(v) }
        if let v = value as? String, let d = Double(v) { return d }
        return defaultValue
    }
    
    private func parseDoubleOptional(_ value: Any?) -> Double? {
        if let v = value as? Double { return v }
        if let v = value as? Int { return Double(v) }
        if let v = value as? String, let d = Double(v) { return d }
        return nil
    }

    private func todoManager(for subagentId: String?) -> TodoManager {
        guard let subagentId else { return todoManager }
        if let manager = todoManagers[subagentId] {
            return manager
        }
        return todoManager
    }

    private func supportsVision(for subagentId: String?) -> Bool {
        guard let subagentId else { return mainModelSupportsVision }
        return subagentVisionSupport[subagentId] ?? mainModelSupportsVision
    }
}

enum SubagentToolError: Error, LocalizedError {
    case unknownTool(String)
    
    var errorDescription: String? {
        switch self {
        case .unknownTool(let name):
            return "Unknown tool: \(name)"
        }
    }
}

enum SearchProviderError: Error, LocalizedError {
    case missingAPIKey(String)
    
    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "\(provider) API key not configured."
        }
    }
}
