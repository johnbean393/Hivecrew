import XCTest
@testable import HivecrewLLM

final class GoogleAIStudioBaseURLTests: XCTestCase {
    func testNativeGoogleBaseURLIsNormalizedToOpenAICompatibilityEndpoint() {
        let baseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!

        let normalized = normalizedLLMProviderBaseURL(baseURL)

        XCTAssertEqual(
            normalized?.absoluteString,
            "https://generativelanguage.googleapis.com/v1beta/openai"
        )
    }

    func testExistingOpenAICompatibleGoogleBaseURLIsLeftUntouched() {
        let baseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai")!

        let normalized = normalizedLLMProviderBaseURL(baseURL)

        XCTAssertEqual(
            normalized?.absoluteString,
            "https://generativelanguage.googleapis.com/v1beta/openai"
        )
    }

    func testNonGoogleProviderBaseURLIsLeftUntouched() {
        let baseURL = URL(string: "https://api.openai.com/v1")!

        let normalized = normalizedLLMProviderBaseURL(baseURL)

        XCTAssertEqual(normalized, baseURL)
    }
}
