//
//  TaskTitleGenerator.swift
//  Hivecrew
//
//  Service for generating concise task titles using LLM
//

import Foundation
import HivecrewLLM

/// Service for generating concise task titles from task descriptions using LLM
class TaskTitleGenerator {
    
    /// Generate a concise title from a task description
    ///
    /// Example: "Research places to visit in Paris and create a Word document"
    ///       -> "Create Paris Trip Research `docx`"
    ///
    /// - Parameters:
    ///   - description: The full task description from the user
    ///   - client: The LLM client to use for generation
    /// - Returns: A concise title (max 6 words)
    func generateTitle(from description: String, using client: any LLMClientProtocol) async throws -> String {
        let prompt = """
        Generate a concise task title (max 6 words) for this task.
        If it involves creating a file, include the file type in backticks (e.g., `docx`, `pdf`, `xlsx`).
        Only respond with the title, nothing else.
        
        Task: \(description)
        
        Title:
        """
        
        let messages = [LLMMessage.user(prompt)]
        
        let response = try await client.chat(messages: messages, tools: nil)
        
        guard let text = response.text else {
            // Fallback: use first 6 words of description
            return fallbackTitle(from: description)
        }
        
        // Clean up the response
        let title = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "Title:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Ensure title is not empty
        if title.isEmpty {
            return fallbackTitle(from: description)
        }
        
        return title
    }
    
    /// Fallback title generation when LLM fails
    private func fallbackTitle(from description: String) -> String {
        let words = description.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .prefix(6)
        
        if words.isEmpty {
            return "New Task"
        }
        
        var title = words.joined(separator: " ")
        if words.count == 6 && description.components(separatedBy: .whitespacesAndNewlines).count > 6 {
            title += "..."
        }
        
        return title
    }
    
    /// Generate title synchronously using a simple heuristic (no LLM)
    /// Use this for immediate UI feedback before async LLM call completes
    func generateQuickTitle(from description: String) -> String {
        fallbackTitle(from: description)
    }
}
