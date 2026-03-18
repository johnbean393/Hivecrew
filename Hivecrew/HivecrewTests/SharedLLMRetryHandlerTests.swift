import Foundation
import HivecrewLLM
import Testing
@testable import Hivecrew

@MainActor
struct SharedLLMRetryHandlerTests {

    @Test
    func retriesTransientErrorsUntilSuccess() async throws {
        let client = MockRetryLLMClient(outcomes: [
            .failure(.timeout),
            .failure(.networkError(underlying: URLError(.networkConnectionLost))),
            .success(Self.makeResponse(text: "Recovered"))
        ])

        let outcome = try await SharedLLMRetryHandler.callWithRetry(
            llmClient: client,
            messages: [.user("Investigate the issue")],
            tools: nil,
            imageScaleLevel: .medium,
            onReasoningUpdate: nil,
            onContentUpdate: nil,
            llmCall: { messages, tools, _, _ in
                try await client.chat(messages: messages, tools: tools)
            },
            options: .init(
                maxLLMRetries: 3,
                maxContextCompactionRetries: 1,
                baseRetryDelay: 0,
                proactiveCompactionPasses: 1,
                normalToolResultLimit: 12_000,
                aggressiveToolResultLimit: 8_000
            ),
            hooks: .init(logInfo: { _ in })
        )

        #expect(outcome.response.text == "Recovered")
        #expect(await client.invocationCount() == 3)
    }

    @Test
    func doesNotRetryCancellationErrors() async throws {
        let client = MockRetryLLMClient(outcomes: [
            .failure(.cancelled),
            .success(Self.makeResponse(text: "Should not be returned"))
        ])

        do {
            _ = try await SharedLLMRetryHandler.callWithRetry(
                llmClient: client,
                messages: [.user("Investigate the issue")],
                tools: nil,
                imageScaleLevel: .medium,
                onReasoningUpdate: nil,
                onContentUpdate: nil,
                llmCall: { messages, tools, _, _ in
                    try await client.chat(messages: messages, tools: tools)
                },
                options: .init(
                    maxLLMRetries: 3,
                    maxContextCompactionRetries: 1,
                    baseRetryDelay: 0,
                    proactiveCompactionPasses: 1,
                    normalToolResultLimit: 12_000,
                    aggressiveToolResultLimit: 8_000
                ),
                hooks: .init(logInfo: { _ in })
            )
            Issue.record("Expected cancellation to be thrown")
        } catch let error as LLMError {
            guard case .cancelled = error else {
                Issue.record("Expected LLMError.cancelled, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected LLMError.cancelled, got \(error)")
        }

        #expect(await client.invocationCount() == 1)
    }

    private static func makeResponse(text: String) -> LLMResponse {
        LLMResponse(
            id: UUID().uuidString,
            model: "test-model",
            created: Date(),
            choices: [
                LLMResponseChoice(
                    index: 0,
                    message: .assistant(text),
                    finishReason: .stop
                )
            ],
            usage: nil
        )
    }
}

private actor MockRetryLLMClient: LLMClientProtocol {
    nonisolated let configuration = LLMConfiguration(
        displayName: "Test",
        baseURL: URL(string: "https://example.com/v1"),
        apiKey: "test-key",
        model: "test-model"
    )

    private var outcomes: [Result<LLMResponse, LLMError>]
    private var calls: Int = 0

    init(outcomes: [Result<LLMResponse, LLMError>]) {
        self.outcomes = outcomes
    }

    func chat(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?
    ) async throws -> LLMResponse {
        calls += 1
        guard !outcomes.isEmpty else {
            throw LLMError.unknown(message: "No mock outcome configured")
        }
        let outcome = outcomes.removeFirst()
        return try outcome.get()
    }

    func chatWithStreaming(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        onReasoningUpdate: ReasoningStreamCallback?,
        onContentUpdate: ContentStreamCallback?
    ) async throws -> LLMResponse {
        try await chat(messages: messages, tools: tools)
    }

    func chatWithReasoningStream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        onReasoningUpdate: ReasoningStreamCallback?
    ) async throws -> LLMResponse {
        try await chat(messages: messages, tools: tools)
    }

    func testConnection() async throws -> Bool {
        true
    }

    func listModels() async throws -> [String] {
        [configuration.model]
    }

    func listModelsDetailed() async throws -> [LLMProviderModel] {
        []
    }

    func invocationCount() -> Int {
        calls
    }
}
