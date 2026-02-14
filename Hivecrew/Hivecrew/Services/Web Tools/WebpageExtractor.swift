//
//  WebpageExtractor.swift
//  Hivecrew
//
//  LLM-powered webpage information extraction
//

import Foundation
import HivecrewLLM

public class WebpageExtractor {
    
    /// Extract specific information from a webpage using LLM
    /// - Parameters:
    ///   - url: The URL of the webpage
    ///   - question: The question to answer based on webpage content
    ///   - taskProviderId: The provider ID for the task's main model
    ///   - taskModelId: The model ID for the task's main model
    ///   - taskService: Task service to create worker LLM client
    /// - Returns: The answer to the question
    static func extractInfo(
        url: URL,
        question: String,
        taskProviderId: String,
        taskModelId: String,
        taskService: Any
    ) async throws -> String {
        // Fetch webpage content
        let content = try await WebpageReader.readWebpage(url: url)
        
        // Use the required worker model for extraction.
        // Cast taskService to access createWorkerLLMClient
        guard let service = taskService as? (any CreateWorkerClientProtocol) else {
            throw WebpageExtractorError.invalidTaskService
        }
        
        let client = try await service.createWorkerLLMClient(
            fallbackProviderId: taskProviderId,
            fallbackModelId: taskModelId
        )
        
        let prompt = """
        Based on the following webpage content, answer this question concisely. Use the webpage content ONLY. Do not use any other information.
        
        Question: \(question)
        
        Webpage content:
        \(content.prefix(100000))
        
        Answer:
        """
        
        let messages = [LLMMessage.user(prompt)]
        let response = try await client.chat(messages: messages, tools: nil)
        
        return response.text ?? "Unable to extract information from webpage"
    }
    
    enum WebpageExtractorError: LocalizedError {
        case invalidTaskService
        
        var errorDescription: String? {
            switch self {
            case .invalidTaskService:
                return "Invalid task service provided"
            }
        }
    }
}

// Protocol for creating worker LLM clients
public protocol CreateWorkerClientProtocol: AnyObject {
    func createWorkerLLMClient(fallbackProviderId: String, fallbackModelId: String) async throws -> any LLMClientProtocol
}
