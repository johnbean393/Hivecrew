//
//  ToolSchemaBuilder.swift
//  HivecrewLLM
//
//  Converts AgentMethod definitions to OpenAI function calling format
//

import Foundation
import HivecrewAgentProtocol

/// Builds OpenAI-compatible tool definitions from AgentMethod enum
public final class ToolSchemaBuilder: Sendable {
    
    public init() {}
    
    /// Build CUA (Computer Use Agent) tools
    /// Note: Screenshot and healthCheck are NOT included because they are internal tools
    /// used by the agent loop, not called by the LLM.
    public func buildCUATools() -> [LLMToolDefinition] {
        AgentMethod.allCases
            .filter { !$0.isInternalTool }
            .map { buildToolDefinition(for: $0) }
    }
    
    /// Build CUA tools excluding specific methods
    /// - Parameter excluding: Methods to exclude from the tool list
    public func buildCUATools(excluding: Set<AgentMethod>) -> [LLMToolDefinition] {
        AgentMethod.allCases
            .filter { !$0.isInternalTool && !excluding.contains($0) }
            .map { buildToolDefinition(for: $0) }
    }
    
    /// Build tool definitions for a subset of methods
    public func buildTools(for methods: [AgentMethod]) -> [LLMToolDefinition] {
        methods.map { buildToolDefinition(for: $0) }
    }
    
    /// Build CUA tools merged with additional tools (e.g., MCP tools)
    /// - Parameter additionalTools: Additional tool definitions to include (e.g., from MCP servers)
    /// - Returns: Combined array of built-in and additional tools
    public func buildToolsWithAdditional(_ additionalTools: [LLMToolDefinition]) -> [LLMToolDefinition] {
        var tools = buildCUATools()
        tools.append(contentsOf: additionalTools)
        return tools
    }
    
    /// Build CUA tools merged with additional tools, excluding specific methods
    /// - Parameters:
    ///   - excluding: Built-in methods to exclude
    ///   - additionalTools: Additional tool definitions to include
    /// - Returns: Combined array of tools
    public func buildToolsWithAdditional(_ additionalTools: [LLMToolDefinition], excluding: Set<AgentMethod>) -> [LLMToolDefinition] {
        var tools = buildCUATools(excluding: excluding)
        tools.append(contentsOf: additionalTools)
        return tools
    }
    
    /// Build a single tool definition
    public func buildToolDefinition(for method: AgentMethod) -> LLMToolDefinition {
        let (description, parameters) = getSchemaInfo(for: method)
        
        return LLMToolDefinition.function(
            name: method.rawValue,
            description: description,
            parameters: parameters
        )
    }
}
