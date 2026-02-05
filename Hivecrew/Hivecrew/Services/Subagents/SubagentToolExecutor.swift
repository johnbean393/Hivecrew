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
    private let taskProviderId: String
    private let taskModelId: String
    private weak var taskService: (any CreateWorkerClientProtocol)?
    private let todoManager: TodoManager
    private let modelContext: ModelContext?
    
    init(
        connection: GuestAgentConnection,
        vmScheduler: VMToolScheduler,
        vmId: String,
        taskProviderId: String,
        taskModelId: String,
        taskService: (any CreateWorkerClientProtocol)?,
        todoManager: TodoManager,
        modelContext: ModelContext?
    ) {
        self.connection = connection
        self.vmScheduler = vmScheduler
        self.vmId = vmId
        self.taskProviderId = taskProviderId
        self.taskModelId = taskModelId
        self.taskService = taskService
        self.todoManager = todoManager
        self.modelContext = modelContext
    }
    
    func execute(toolCall: LLMToolCall) async throws -> ToolResult {
        let args = try toolCall.function.argumentsDictionary()
        let name = toolCall.function.name
        
        switch name {
        case "run_shell":
            return try await executeRunShell(args: args)
        case "read_file":
            return try await executeReadFile(args: args)
        case "move_file":
            return try await executeMoveFile(args: args)
        case "wait":
            return try await executeWait(args: args)
        case "web_search":
            return try await executeWebSearch(args: args)
        case "read_webpage_content":
            return try await executeReadWebpageContent(args: args)
        case "extract_info_from_webpage":
            return try await executeExtractInfoFromWebpage(args: args)
        case "get_location":
            return try await executeGetLocation()
        case "create_todo_list":
            return try executeCreateTodoList(args: args)
        case "add_todo_item":
            return try executeAddTodoItem(args: args)
        case "finish_todo_item":
            return try executeFinishTodoItem(args: args)
        case "generate_image":
            return try await executeGenerateImage(args: args)
        default:
            if MCPServerManager.shared.isMCPTool(name) {
                return try await executeMCPTool(name: name, args: args)
            }
            throw SubagentToolError.unknownTool(name)
        }
    }
    
    // MARK: - VM Tools
    
    private func executeRunShell(args: [String: Any]) async throws -> ToolResult {
        let command = args["command"] as? String ?? ""
        let timeout = parseDoubleOptional(args["timeout"])
        let result = try await vmScheduler.run {
            try await self.connection.runShell(command: command, timeout: timeout)
        }
        var output = "Exit code: \(result.exitCode)"
        if !result.stdout.isEmpty { output += "\nstdout: \(result.stdout.prefix(2000))" }
        if !result.stderr.isEmpty { output += "\nstderr: \(result.stderr.prefix(2000))" }
        return .text(output)
    }
    
    private func executeReadFile(args: [String: Any]) async throws -> ToolResult {
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
            return .image(description: desc, base64: base64, mimeType: mimeType)
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
    
    private func executeCreateTodoList(args: [String: Any]) throws -> ToolResult {
        let title = args["title"] as? String ?? "Untitled"
        let items = args["items"] as? [String]
        let list = todoManager.createList(title: title, items: items)
        var result = "✓ Created: \(list.title)\n"
        for (i, item) in list.items.enumerated() {
            result += "\(i+1). \(item.isCompleted ? "[✓]" : "[ ]") \(item.text)\n"
        }
        return .text(result)
    }
    
    private func executeAddTodoItem(args: [String: Any]) throws -> ToolResult {
        let itemText = args["item"] as? String ?? ""
        let index = try todoManager.addItem(itemText: itemText)
        return .text("✓ Added item #\(index): \(itemText)")
    }
    
    private func executeFinishTodoItem(args: [String: Any]) throws -> ToolResult {
        let index = args["index"] as? Int ?? 0
        try todoManager.finishItem(index: index)
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
        guard UserDefaults.standard.bool(forKey: "imageGenerationEnabled") else {
            return nil
        }
        
        let providerString = UserDefaults.standard.string(forKey: "imageGenerationProvider") ?? "openRouter"
        let model = UserDefaults.standard.string(forKey: "imageGenerationModel") ?? ""
        
        guard !model.isEmpty else {
            return nil
        }
        
        guard let modelContext = self.modelContext else {
            return nil
        }
        
        let provider = ImageGenerationProvider(rawValue: providerString) ?? .openRouter
        
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
