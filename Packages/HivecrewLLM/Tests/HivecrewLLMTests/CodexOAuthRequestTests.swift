import XCTest
@testable import HivecrewLLM

final class CodexOAuthRequestTests: XCTestCase {
    func testCodexOAuthResponsesBodySetsStoreFalse() throws {
        let body = try buildCodexOAuthRequestBodyForTests(
            model: "gpt-5.4",
            messages: [
                LLMMessage.user("Create a 3D model of this water bottle.")
            ],
            tools: nil,
            stream: false
        )

        XCTAssertEqual(body["store"] as? Bool, false)
    }

    func testCodexOAuthResponsesBodyAddsDefaultInstructionsWhenMissingSystemPrompt() throws {
        let body = try buildCodexOAuthRequestBodyForTests(
            model: "gpt-5.4",
            messages: [
                LLMMessage.user("Did the task complete successfully?")
            ],
            tools: nil,
            stream: false
        )

        XCTAssertEqual(body["instructions"] as? String, "You are a helpful assistant.")
    }

    func testCodexOAuthAssistantReplayUsesOutputTextContent() throws {
        let toolCall = LLMToolCall(
            id: "call_123",
            type: "function",
            function: LLMFunctionCall(
                name: "create_todo_list",
                arguments: "{\"items\":[\"Create mesh\",\"Generate texture\"]}"
            )
        )
        let body = try buildCodexOAuthRequestBodyForTests(
            model: "gpt-5.4",
            messages: [
                LLMMessage.user("Create a 3D model of this water bottle."),
                LLMMessage.assistant("I will plan the work first.", toolCalls: [toolCall]),
                LLMMessage.toolResult(toolCallId: "call_123", content: "{\"ok\":true}")
            ],
            tools: nil,
            stream: false
        )

        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let assistantMessage = try XCTUnwrap(
            input.first(where: {
                ($0["type"] as? String) == "message" && ($0["role"] as? String) == "assistant"
            })
        )
        let assistantContent = try XCTUnwrap(assistantMessage["content"] as? [[String: Any]])

        XCTAssertEqual(assistantContent.first?["type"] as? String, "output_text")
        XCTAssertEqual(assistantContent.first?["text"] as? String, "I will plan the work first.")
        XCTAssertTrue(input.contains(where: { ($0["type"] as? String) == "function_call" }))
        XCTAssertTrue(input.contains(where: { ($0["type"] as? String) == "function_call_output" }))
    }

    func testCodexOAuthModelsAreAlwaysMarkedVisionCapable() {
        let model = LLMProviderModel(
            id: "gpt-5.4",
            name: "gpt-5.4",
            description: nil,
            contextLength: 272000,
            createdAt: nil,
            inputModalities: ["text"],
            outputModalities: ["text"],
            supportsVisionInput: nil
        )

        let normalized = normalizeProviderModelMetadata(model, backendMode: .codexOAuth)

        XCTAssertEqual(normalized.supportsVisionInput, true)
        XCTAssertEqual(normalized.inputModalities, ["text", "image"])
        XCTAssertTrue(normalized.isVisionCapable)
    }

    func testParsesCodexCLIVersionFromStandardOutput() {
        XCTAssertEqual(
            parsedCodexCLIClientVersion(from: "codex-cli 0.107.0\n"),
            "0.107.0"
        )
    }

    func testReturnsNilWhenCodexCLIVersionCannotBeParsed() {
        XCTAssertNil(parsedCodexCLIClientVersion(from: "codex-cli dev-build"))
    }

    func testBuildCodexOAuthModelsURLIncludesClientVersion() {
        let url = buildCodexOAuthURL(pathComponent: "models", clientVersion: "0.107.0")
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

        XCTAssertEqual(url.path, "/backend-api/codex/models")
        XCTAssertEqual(
            components?.queryItems?.first(where: { $0.name == codexOAuthClientVersionQueryName })?.value,
            "0.107.0"
        )
    }

    func testBuildCodexOAuthResponsesURLIncludesClientVersion() {
        let url = buildCodexOAuthURL(pathComponent: "responses", clientVersion: "0.107.0")
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

        XCTAssertEqual(url.path, "/backend-api/codex/responses")
        XCTAssertEqual(
            components?.queryItems?.first(where: { $0.name == codexOAuthClientVersionQueryName })?.value,
            "0.107.0"
        )
    }
}
