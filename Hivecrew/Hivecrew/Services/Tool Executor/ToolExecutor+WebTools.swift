//
//  ToolExecutor+WebTools.swift
//  Hivecrew
//
//  Web-related tool handlers for ToolExecutor
//

import Foundation
import GoogleSearch

// MARK: - Web Tool Handlers

extension ToolExecutor {
    
    /// Execute web search tool
    func executeWebSearchTool(args: [String: Any]) async throws -> InternalToolResult {
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
            let googleResults = try await GoogleSearch.search(
                query: query,
                site: site,
                resultCount: resultCount,
                startDate: startDate,
                endDate: endDate
            )
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
        return .text(output)
    }
    
    /// Execute read webpage content tool
    func executeReadWebpageContent(args: [String: Any]) async throws -> InternalToolResult {
        let urlString = args["url"] as? String ?? ""
        guard let url = URL(string: urlString) else {
            return .text("Error: Invalid URL format")
        }
        let content = try await WebpageReader.readWebpage(url: url)
        return .text(content)
    }
    
    /// Execute extract info from webpage tool
    func executeExtractInfoFromWebpage(args: [String: Any], taskProviderId: String, taskModelId: String, taskService: (any CreateWorkerClientProtocol)?) async throws -> InternalToolResult {
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
    
    /// Execute get location tool
    func executeGetLocation() async throws -> InternalToolResult {
        let location = try await IPLocation.getLocation()
        return .text("Your location: \(location)")
    }
}
