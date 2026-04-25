//
//  RuntimeClassifierTests.swift
//  HivecrewTests
//
//  Tests for RuntimeClassifier Phase 2 heuristics.
//

import Foundation
import Testing
import HivecrewCore
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
func classifierGUITaskGoesToVM() throws {
    let classifier = RuntimeClassifier()
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
        #expect(decision.assignedKind == .isolatedVM, "Expected VM for: \(desc)")
    }
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
