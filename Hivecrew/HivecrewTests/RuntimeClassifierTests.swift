//
//  RuntimeClassifierTests.swift
//  HivecrewTests
//
//  Tests for RuntimeClassifier Phase 2 heuristics.
//

import Foundation
import Testing
import HivecrewCore
import HivecrewLLM
@testable import Hivecrew

// MARK: - Helpers

@MainActor
private func makeTaskRecord(
    description: String,
    runtimeTarget: TaskRuntimeTarget = .automatic
) -> TaskRecord {
    let task = TaskRecord(
        title: "Test",
        taskDescription: description,
        providerId: "test-provider",
        modelId: "test-model",
        runtimeTarget: runtimeTarget
    )
    return task
}

// MARK: - Explicit target tests

@Test @MainActor
func classifierExplicitFast() throws {
    let classifier = RuntimeClassifier()
    let task = makeTaskRecord(description: "Write a report", runtimeTarget: .fast)
    let decision = try classifier.classify(task)
    #expect(decision.assignedKind == .fast)
}

@Test @MainActor
func classifierExplicitVM() throws {
    let classifier = RuntimeClassifier()
    let task = makeTaskRecord(description: "Write a report", runtimeTarget: .isolatedVM)
    let decision = try classifier.classify(task)
    #expect(decision.assignedKind == .isolatedVM)
}

@Test @MainActor
func classifierExplicitAppSucceedsWhenReady() throws {
    var classifier = RuntimeClassifier()
    classifier.appWorkerSetupCheck = { nil }
    let task = makeTaskRecord(description: "Open Calculator and click 7", runtimeTarget: .app)
    let decision = try classifier.classify(task)
    #expect(decision.assignedKind == .app)
    #expect(decision.requirement.riskLevel == .trustedGUI)
    #expect(decision.requirement.requiredCapabilities == .app)
}

@Test @MainActor
func classifierExplicitAppThrowsWhenPermissionsMissing() throws {
    var classifier = RuntimeClassifier()
    classifier.appWorkerSetupCheck = { .appPermissionsMissing }
    let task = makeTaskRecord(description: "Write a report", runtimeTarget: .app)
    do {
        _ = try classifier.classify(task)
        Issue.record("Expected RuntimeClassificationError.appUnavailable")
    } catch let error as RuntimeClassificationError {
        if case .appUnavailable(let req) = error {
            #expect(req.reason == .appPermissionsMissing)
            #expect(req.runtimeKind == .app)
        } else {
            Issue.record("Expected appUnavailable, got \(error)")
        }
    }
}

@Test @MainActor
func classifierExplicitAppThrowsWhenBinaryMissing() throws {
    var classifier = RuntimeClassifier()
    classifier.appWorkerSetupCheck = { .cuaDriverMissing }
    let task = makeTaskRecord(description: "Open Safari", runtimeTarget: .app)
    do {
        _ = try classifier.classify(task)
        Issue.record("Expected RuntimeClassificationError.appUnavailable")
    } catch let error as RuntimeClassificationError {
        if case .appUnavailable(let req) = error {
            #expect(req.reason == .cuaDriverMissing)
        } else {
            Issue.record("Expected appUnavailable, got \(error)")
        }
    }
}

// MARK: - Automatic classification heuristics

@Test @MainActor
func classifierHeadlessTaskGoesToFast() throws {
    let classifier = RuntimeClassifier()
    let task = makeTaskRecord(description: "Summarize the attached PDF and produce a CSV output")
    let decision = try classifier.classify(task)
    #expect(decision.assignedKind == .fast)
}

@Test @MainActor
func classifierGUITaskGoesToAppWhenAvailable() throws {
    var classifier = RuntimeClassifier()
    classifier.appWorkerAvailable = { true }
    let guiDescriptions = [
        "Open my browser and navigate to google.com",
        "Click on the submit button",
        "Open Safari and download the file",
        "Take a screenshot of the desktop",
        "Open Finder and navigate to Documents",
    ]
    for desc in guiDescriptions {
        let task = makeTaskRecord(description: desc)
        let decision = try classifier.classify(task)
        #expect(decision.assignedKind == .app, "Expected App Worker for: \(desc)")
    }
}

@Test @MainActor
func classifierInteractiveWebsiteTaskGoesToAppWhenAvailable() throws {
    var classifier = RuntimeClassifier()
    classifier.appWorkerAvailable = { true }
    let webDescriptions = [
        "Open Google and play tic tac toe",
        "Use Chrome to fill out the form on example.com",
        "Navigate to https://example.com and click the signup button",
        "Open reddit and click the top post",
    ]
    for desc in webDescriptions {
        let task = makeTaskRecord(description: desc)
        let decision = try classifier.classify(task)
        #expect(decision.assignedKind == .app, "Expected App Worker for: \(desc)")
    }
}

@Test @MainActor
func classifierInteractiveWebsiteTaskFallsBackToVMWhenAppUnavailable() throws {
    var classifier = RuntimeClassifier()
    classifier.appWorkerAvailable = { false }
    let task = makeTaskRecord(description: "Open Google and play tic tac toe")
    let decision = try classifier.classify(task)
    #expect(decision.assignedKind == .isolatedVM)
}

@Test @MainActor
func classifierWebResearchStillGoesToFast() throws {
    let classifier = RuntimeClassifier()
    let task = makeTaskRecord(description: "Search the web for recent Swift concurrency articles and summarize them")
    let decision = try classifier.classify(task)
    #expect(decision.assignedKind == .fast)
}

@Test @MainActor
func classifierIsolationTaskGoesToVM() throws {
    let classifier = RuntimeClassifier()
    let isolationDescriptions = [
        "Run this untrusted binary in a safe environment",
        "Install this .dmg file and test it",
        "Install this .pkg and check what it does",
        "Sandbox this process and monitor it",
    ]
    for desc in isolationDescriptions {
        let task = makeTaskRecord(description: desc)
        let decision = try classifier.classify(task)
        #expect(decision.assignedKind == .isolatedVM, "Expected VM for: \(desc)")
    }
}

@Test @MainActor
func classifierDefaultsToFast() throws {
    let classifier = RuntimeClassifier()
    let normalDescriptions = [
        "Write a Python script to process data",
        "Create a markdown report from the attached files",
        "Run npm install and build the project",
        "Parse the JSON file and extract the email addresses",
    ]
    for desc in normalDescriptions {
        let task = makeTaskRecord(description: desc)
        let decision = try classifier.classify(task)
        #expect(decision.assignedKind == .fast, "Expected Fast for: \(desc)")
    }
}

// MARK: - Inline override parsing

@Test
func parseInlineOverrideRecognisesFast() {
    let result = RuntimeClassifier.parseInlineOverride(in: "Refactor this module @fast please")
    #expect(result?.runtimeTarget == .fast)
    #expect(result?.cleanedDescription == "Refactor this module please")
}

@Test
func parseInlineOverrideRecognisesVM() {
    let result = RuntimeClassifier.parseInlineOverride(in: "@vm open chrome and screenshot google")
    #expect(result?.runtimeTarget == .isolatedVM)
    #expect(result?.cleanedDescription == "open chrome and screenshot google")
}

@Test
func parseInlineOverrideRecognisesApp() {
    let result = RuntimeClassifier.parseInlineOverride(in: "Send an email from my mail app @app")
    #expect(result?.runtimeTarget == .app)
    #expect(result?.cleanedDescription == "Send an email from my mail app")
}

@Test
func parseInlineOverrideRecognisesAutomatic() {
    let result = RuntimeClassifier.parseInlineOverride(in: "Do something smart @auto")
    #expect(result?.runtimeTarget == .automatic)
    #expect(result?.cleanedDescription == "Do something smart")
}

@Test
func parseInlineOverrideIgnoresUnknownToken() {
    let result = RuntimeClassifier.parseInlineOverride(in: "Notify @alice about the deploy")
    #expect(result == nil)
}

@Test
func parseInlineOverrideDoesNotMatchInsideEmail() {
    // The "@" must follow whitespace or be at the start, so an email address
    // shouldn't trigger an override even if it contains a runtime keyword.
    let result = RuntimeClassifier.parseInlineOverride(in: "Email me at fast@example.com")
    #expect(result == nil)
}

// MARK: - Async classification

@Test @MainActor
func classifyAsyncFallsBackToHeuristicWhenNoWorker() async throws {
    var classifier = RuntimeClassifier()
    classifier.appWorkerAvailable = { true }
    let task = makeTaskRecord(description: "Open Safari and navigate to a page")
    let decision = try await classifier.classifyAsync(task)
    #expect(decision.assignedKind == .app)
}

@Test @MainActor
func classifyAsyncHonorsExplicitFast() async throws {
    let classifier = RuntimeClassifier()
    let task = makeTaskRecord(description: "Open Safari and navigate to a page", runtimeTarget: .fast)
    let decision = try await classifier.classifyAsync(task)
    #expect(decision.assignedKind == .fast)
}

@Test @MainActor
func classifyAsyncHonorsWorkerAppChoiceForWebsiteInteraction() async throws {
    var classifier = RuntimeClassifier()
    classifier.appWorkerAvailable = { true }
    classifier.workerClientProvider = {
        MockRuntimeRouterClient(text: #"{"runtime":"app","reason":"browser"}"#)
    }
    let task = makeTaskRecord(description: "Open Google and play tic tac toe")
    let decision = try await classifier.classifyAsync(task)
    #expect(decision.assignedKind == .app)
}

private actor MockRuntimeRouterClient: LLMClientProtocol {
    nonisolated let configuration = LLMConfiguration(
        displayName: "Runtime Router Test",
        baseURL: URL(string: "https://example.com/v1"),
        apiKey: "test-key",
        model: "test-model"
    )

    private let text: String

    init(text: String) {
        self.text = text
    }

    func chat(messages: [LLMMessage], tools: [LLMToolDefinition]?) async throws -> LLMResponse {
        LLMResponse(
            id: UUID().uuidString,
            model: configuration.model,
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

    func testConnection() async throws -> Bool { true }

    func listModels() async throws -> [String] { [configuration.model] }
}
