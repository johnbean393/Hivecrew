//
//  LLMService.swift
//  HivecrewLLM
//
//  Factory and manager for LLM clients
//

import Foundation

/// Service for creating and managing LLM clients
///
/// This service provides a factory pattern for creating LLM clients
/// with different configurations. Each client instance is independent
/// and thread-safe for concurrent use.
public final class LLMService: Sendable {
    
    /// Shared instance for convenience
    public static let shared = LLMService()
    
    /// The tool schema builder for creating tool definitions
    public let toolSchemaBuilder: ToolSchemaBuilder
    
    public init() {
        self.toolSchemaBuilder = ToolSchemaBuilder()
    }
    
    /// Create an LLM client from a configuration
    ///
    /// Each call creates a new, independent client instance that is
    /// safe to use from any thread/task. Multiple agents can use
    /// separate clients concurrently without interference.
    ///
    /// - Parameter configuration: The configuration for the client
    /// - Returns: An LLM client instance
    public func createClient(from configuration: LLMConfiguration) -> any LLMClientProtocol {
        OpenAICompatibleClient(configuration: configuration)
    }
    
    /// Create an LLM client with inline parameters
    ///
    /// Convenience method for creating a client without building a configuration first.
    ///
    /// - Parameters:
    ///   - apiKey: The API key for authentication
    ///   - model: The model to use (e.g., "gpt-4o")
    ///   - baseURL: Optional custom base URL
    ///   - organizationId: Optional organization ID
    ///   - displayName: Optional display name for logging
    /// - Returns: An LLM client instance
    public func createClient(
        apiKey: String,
        model: String,
        baseURL: URL? = nil,
        organizationId: String? = nil,
        displayName: String? = nil
    ) -> any LLMClientProtocol {
        let configuration = LLMConfiguration(
            displayName: displayName ?? model,
            baseURL: baseURL,
            apiKey: apiKey,
            model: model,
            organizationId: organizationId
        )
        return createClient(from: configuration)
    }
    
    /// Test a configuration by making a simple API call
    ///
    /// - Parameter configuration: The configuration to test
    /// - Returns: True if the connection was successful
    /// - Throws: LLMError if the connection fails
    public func testConfiguration(_ configuration: LLMConfiguration) async throws -> Bool {
        let client = createClient(from: configuration)
        return try await client.testConnection()
    }
}

// MARK: - Common Provider Configurations

extension LLMService {
    /// Create a client for the standard OpenAI API
    public func createOpenAIClient(
        apiKey: String,
        model: String = "gpt-4o",
        organizationId: String? = nil
    ) -> any LLMClientProtocol {
        createClient(
            apiKey: apiKey,
            model: model,
            baseURL: nil,
            organizationId: organizationId,
            displayName: "OpenAI"
        )
    }
    
    /// Create a client for Azure OpenAI
    ///
    /// Azure OpenAI requires a specific endpoint format:
    /// https://{your-resource-name}.openai.azure.com/openai/deployments/{deployment-id}
    public func createAzureClient(
        endpoint: URL,
        apiKey: String,
        deploymentId: String
    ) -> any LLMClientProtocol {
        createClient(
            apiKey: apiKey,
            model: deploymentId,
            baseURL: endpoint,
            displayName: "Azure OpenAI"
        )
    }
    
    /// Create a client for a local LLM server (e.g., Ollama, LM Studio)
    ///
    /// Most local servers run on localhost with a specific port.
    /// Ollama default: http://localhost:11434/v1
    /// LM Studio default: http://localhost:1234/v1
    public func createLocalClient(
        baseURL: URL,
        model: String,
        apiKey: String = "not-required"
    ) -> any LLMClientProtocol {
        createClient(
            apiKey: apiKey,
            model: model,
            baseURL: baseURL,
            displayName: "Local LLM"
        )
    }
}
