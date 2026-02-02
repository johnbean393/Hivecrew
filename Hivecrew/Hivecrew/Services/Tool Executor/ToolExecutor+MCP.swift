//
//  ToolExecutor+MCP.swift
//  Hivecrew
//
//  MCP tool execution handlers for ToolExecutor
//

import Foundation
import HivecrewMCP

// MARK: - MCP Tool Handlers

extension ToolExecutor {
    
    /// Check if a tool name is an MCP tool
    func isMCPTool(_ name: String) -> Bool {
        name.hasPrefix("mcp_")
    }
    
    /// Execute an MCP tool call
    func executeMCPTool(name: String, args: [String: Any]) async throws -> InternalToolResult {
        let mcpManager = MCPServerManager.shared
        
        do {
            let result = try await mcpManager.executeTool(name: name, arguments: args)
            
            // Check if the result is an error
            if result.isError == true {
                return .text("Error: \(result.textContent)")
            }
            
            // Check for image content
            for content in result.content {
                if content.type == "image", let data = content.data, let mimeType = content.mimeType {
                    return .image(
                        description: content.text ?? "Image from MCP tool",
                        base64: data,
                        mimeType: mimeType
                    )
                }
            }
            
            // Return text content
            let textContent = result.textContent
            if textContent.isEmpty {
                return .text("Tool executed successfully")
            }
            return .text(textContent)
            
        } catch let error as MCPClientError {
            throw ToolExecutorError.mcpError(error.localizedDescription ?? "Unknown MCP error")
        } catch {
            throw ToolExecutorError.mcpError(error.localizedDescription)
        }
    }
}
