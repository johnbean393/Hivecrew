//
//  ContextCompactionPolicyTests.swift
//  HivecrewLLMTests
//

import XCTest
@testable import HivecrewLLM

final class ContextCompactionPolicyTests: XCTestCase {
    func testContextLimitParserExtractsMaxAndRequestedTokens() {
        let message = "This endpoint's maximum context length is 202800 tokens. However, you requested about 237406 tokens (233765 of text input, 3641 of tool input)."
        let parsed = ContextLimitErrorParser.parse(message: message)

        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.maxInputTokens, 202800)
        XCTAssertEqual(parsed?.requestedTokens, 237406)
    }

    func testContextLimitParserIgnoresUnrelatedErrors() {
        let parsed = ContextLimitErrorParser.parse(message: "Authentication failed: invalid API key.")
        XCTAssertNil(parsed)
    }

    func testCompactionPolicyThresholdBoundaryAtEightyFivePercent() {
        let atThreshold = ContextCompactionPolicy.proactiveDecision(
            estimatedPromptTokens: 850,
            maxInputTokens: 1000
        )
        XCTAssertTrue(atThreshold.shouldCompact)
        XCTAssertEqual(atThreshold.reason, .threshold85)
        XCTAssertEqual(atThreshold.fillRatio, 0.85, accuracy: 0.0001)

        let belowThreshold = ContextCompactionPolicy.proactiveDecision(
            estimatedPromptTokens: 849,
            maxInputTokens: 1000
        )
        XCTAssertFalse(belowThreshold.shouldCompact)
        XCTAssertNil(belowThreshold.reason)
    }

    func testCompactionPolicySkipsProactiveCompactionWhenBudgetUnknown() {
        let decision = ContextCompactionPolicy.proactiveDecision(
            estimatedPromptTokens: 1500,
            maxInputTokens: nil
        )
        XCTAssertFalse(decision.shouldCompact)
        XCTAssertNil(decision.reason)
        XCTAssertNil(decision.fillRatio)
    }

    func testCompactionPolicyCompactsForContextExceededErrors() {
        let contextError = LLMError.contextLimitExceeded(
            message: "maximum context length is 128000",
            maxInputTokens: 128000,
            requestedTokens: 140000
        )
        XCTAssertEqual(ContextCompactionPolicy.compactionReason(for: contextError), .contextExceeded)

        let payloadError = LLMError.payloadTooLarge(message: "HTTP 413")
        XCTAssertEqual(ContextCompactionPolicy.compactionReason(for: payloadError), .contextExceeded)
    }

    func testContextBudgetResolverCachesResolvedModelBudget() async {
        let resolver = ContextBudgetResolver(cacheTTL: 3600, unknownCacheTTL: 3600)
        let client = MockLLMClient(
            configuration: LLMConfiguration(
                displayName: "Test",
                baseURL: URL(string: "https://example.com/v1"),
                apiKey: "test",
                model: "provider/model-a"
            ),
            detailedModels: [
                LLMProviderModel(id: "provider/model-a", contextLength: 128000)
            ]
        )

        let first = await resolver.resolve(using: client)
        let second = await resolver.resolve(using: client)

        XCTAssertEqual(first.maxInputTokens, 128000)
        XCTAssertEqual(first.source, .models)
        XCTAssertEqual(second.maxInputTokens, 128000)
        XCTAssertEqual(await client.detailedCallCount(), 1)
    }

    func testContextBudgetResolverLearnsAndKeepsStricterLimit() async {
        let resolver = ContextBudgetResolver(cacheTTL: 3600, unknownCacheTTL: 3600)
        let providerURL = URL(string: "https://example.com/v1")
        let modelID = "provider/model-a"

        _ = await resolver.learnContextLimit(
            providerBaseURL: providerURL,
            modelId: modelID,
            maxInputTokens: 128000,
            requestedTokens: 140000
        )
        _ = await resolver.learnContextLimit(
            providerBaseURL: providerURL,
            modelId: modelID,
            maxInputTokens: 96000,
            requestedTokens: 120000
        )

        let cached = await resolver.cachedBudget(providerBaseURL: providerURL, modelId: modelID)
        XCTAssertEqual(cached?.maxInputTokens, 96000)
        XCTAssertEqual(cached?.source, .errorLearned)
    }

    func testCompactionPolicyDetectsContextErrorFromGenericMessage() {
        struct GenericError: LocalizedError {
            let message: String
            var errorDescription: String? { message }
        }

        let error = GenericError(message: "Context window exceeded: requested 130000 tokens, max context length is 128000.")
        XCTAssertEqual(ContextCompactionPolicy.compactionReason(for: error), .contextExceeded)
    }

    func testCompactionPolicyDetectsMaximumInputExceededMessage() {
        struct GenericError: LocalizedError {
            let message: String
            var errorDescription: String? { message }
        }

        let error = GenericError(message: "Maximum input exceeded for this model.")
        XCTAssertEqual(ContextCompactionPolicy.compactionReason(for: error), .contextExceeded)
    }
}

private actor MockLLMClient: LLMClientProtocol {
    nonisolated let configuration: LLMConfiguration
    private let detailedModels: [LLMProviderModel]
    private var listModelsDetailedInvocations: Int = 0

    init(configuration: LLMConfiguration, detailedModels: [LLMProviderModel]) {
        self.configuration = configuration
        self.detailedModels = detailedModels
    }

    func chat(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?
    ) async throws -> LLMResponse {
        throw LLMError.unknown(message: "Not implemented in mock")
    }

    func chatWithStreaming(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        onReasoningUpdate: ReasoningStreamCallback?,
        onContentUpdate: ContentStreamCallback?
    ) async throws -> LLMResponse {
        throw LLMError.unknown(message: "Not implemented in mock")
    }

    func chatWithReasoningStream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        onReasoningUpdate: ReasoningStreamCallback?
    ) async throws -> LLMResponse {
        throw LLMError.unknown(message: "Not implemented in mock")
    }

    func testConnection() async throws -> Bool {
        true
    }

    func listModels() async throws -> [String] {
        detailedModels.map(\.id)
    }

    func listModelsDetailed() async throws -> [LLMProviderModel] {
        listModelsDetailedInvocations += 1
        return detailedModels
    }

    func detailedCallCount() -> Int {
        listModelsDetailedInvocations
    }
}
