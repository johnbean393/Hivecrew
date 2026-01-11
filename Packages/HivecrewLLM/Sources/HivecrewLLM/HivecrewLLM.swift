//
//  HivecrewLLM.swift
//  HivecrewLLM
//
//  HivecrewLLM provides LLM integration for the Hivecrew agent system.
//
//  Key components:
//  - LLMClientProtocol: Abstract interface for LLM providers
//  - OpenAICompatibleClient: Implementation using MacPaw OpenAI library
//  - LLMService: Factory for creating LLM clients
//  - ToolSchemaBuilder: Converts AgentMethod to OpenAI function definitions
//  - AgentTracer: JSON-line logging for agent execution
//

import Foundation
