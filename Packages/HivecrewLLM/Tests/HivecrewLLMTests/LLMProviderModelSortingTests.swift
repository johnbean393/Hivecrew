import XCTest
@testable import HivecrewLLM

final class LLMProviderModelSortingTests: XCTestCase {
    func testSortByVersionDescendingOrdersGPTFamiliesByNewestVersionFirst() {
        let models = [
            LLMProviderModel(id: "gpt-5.1-codex-mini"),
            LLMProviderModel(id: "gpt-5"),
            LLMProviderModel(id: "gpt-5.4"),
            LLMProviderModel(id: "gpt-5.2-codex"),
            LLMProviderModel(id: "gpt-5.1"),
            LLMProviderModel(id: "gpt-5.3-codex")
        ]

        let sortedIDs = LLMProviderModel.sortByVersionDescending(models).map(\.id)

        XCTAssertEqual(
            sortedIDs,
            [
                "gpt-5.4",
                "gpt-5.3-codex",
                "gpt-5.2-codex",
                "gpt-5.1",
                "gpt-5.1-codex-mini",
                "gpt-5"
            ]
        )
    }

    func testSortByVersionDescendingUsesModelNamesForProviderCatalogs() {
        let models = [
            LLMProviderModel(id: "aion-labs/aion-1.0-mini", name: "AionLabs: Aion-1.0-Mini"),
            LLMProviderModel(id: "aion-labs/aion-2.0", name: "AionLabs: Aion-2.0"),
            LLMProviderModel(id: "aion-labs/aion-1.0", name: "AionLabs: Aion-1.0")
        ]

        let sortedIDs = LLMProviderModel.sortByVersionDescending(models).map(\.id)

        XCTAssertEqual(
            sortedIDs,
            [
                "aion-labs/aion-2.0",
                "aion-labs/aion-1.0",
                "aion-labs/aion-1.0-mini"
            ]
        )
    }

    func testDefaultProtocolListModelsDetailedUsesVersionAwareSort() async throws {
        let client = MockModelListingClient()

        let sortedIDs = try await client.listModelsDetailed().map(\.id)

        XCTAssertEqual(sortedIDs, ["gpt-5.4", "gpt-5.2", "gpt-5.1", "gpt-5"])
    }
}

private struct MockModelListingClient: LLMClientProtocol {
    let configuration = LLMConfiguration(
        displayName: "Mock",
        apiKey: "",
        model: "gpt-5",
        backendMode: .chatCompletions
    )

    func chat(messages: [LLMMessage], tools: [LLMToolDefinition]?) async throws -> LLMResponse {
        throw LLMError.unknown(message: "Not used in sorting tests")
    }

    func chatWithStreaming(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        onReasoningUpdate: ReasoningStreamCallback?,
        onContentUpdate: ContentStreamCallback?
    ) async throws -> LLMResponse {
        throw LLMError.unknown(message: "Not used in sorting tests")
    }

    func chatWithReasoningStream(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        onReasoningUpdate: ReasoningStreamCallback?
    ) async throws -> LLMResponse {
        throw LLMError.unknown(message: "Not used in sorting tests")
    }

    func testConnection() async throws -> Bool {
        true
    }

    func listModels() async throws -> [String] {
        ["gpt-5", "gpt-5.2", "gpt-5.1", "gpt-5.4"]
    }
}
