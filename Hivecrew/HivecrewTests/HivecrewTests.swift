//
//  HivecrewTests.swift
//  HivecrewTests
//
//  Created by John Bean on 1/10/26.
//

import Foundation
import HivecrewLLM
import HivecrewShared
import Testing
@testable import Hivecrew

struct HivecrewTests {

    @Test
    func vmConcurrencyPolicyFallsBackToHostLimit() {
        let suiteName = "HivecrewTests.vmConcurrencyPolicy.fallback.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.removeObject(forKey: "maxConcurrentVMs")

        #expect(VMConcurrencyPolicy.effectiveMaxConcurrentVMs(userDefaults: defaults) == 2)
    }

    @Test
    func vmConcurrencyPolicyClampsStoredValuesToHostLimit() {
        let suiteName = "HivecrewTests.vmConcurrencyPolicy.clamp.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(16, forKey: "maxConcurrentVMs")
        #expect(VMConcurrencyPolicy.effectiveMaxConcurrentVMs(userDefaults: defaults) == 2)

        defaults.set(-3, forKey: "maxConcurrentVMs")
        #expect(VMConcurrencyPolicy.effectiveMaxConcurrentVMs(userDefaults: defaults) == 2)
    }

    @Test
    func resolveReasoningSelectionPrefersHighEffortWhenSupported() {
        let capability = LLMReasoningCapability(
            kind: .effort,
            supportedEfforts: ["low", "medium", "high"],
            defaultEffort: "medium"
        )

        let resolution = resolveReasoningSelection(
            capability: capability,
            currentEnabled: nil,
            currentEffort: nil
        )

        #expect(resolution.enabled == nil)
        #expect(resolution.effort == "high")
    }

    @Test
    func taskRecordContinuationFieldsDefaultToNil() {
        let task = TaskRecord(
            title: "Draft spec",
            taskDescription: "Write a specification",
            providerId: "provider",
            modelId: "model"
        )

        #expect(task.referencedTaskIds == nil)
        #expect(task.continuationSourceTaskId == nil)
        #expect(task.retrievalInlineContextBlocks.isEmpty)
    }

    @Test
    @MainActor
    func inactiveTaskSuggestionsExcludeActiveTasksAndSortByRecency() {
        let now = Date()
        let service = TaskService()

        let runningTask = makeTask(
            id: "running",
            title: "Running",
            taskDescription: "Still active",
            status: .running,
            createdAt: now.addingTimeInterval(-50)
        )
        let olderCompletedTask = makeTask(
            id: "older-completed",
            title: "Older completed",
            taskDescription: "Finished first",
            status: .completed,
            createdAt: now.addingTimeInterval(-500),
            completedAt: now.addingTimeInterval(-300)
        )
        let recentFailedTask = makeTask(
            id: "recent-failed",
            title: "Recent failed",
            taskDescription: "Finished later",
            status: .failed,
            createdAt: now.addingTimeInterval(-200),
            completedAt: now.addingTimeInterval(-100)
        )

        service.tasks = [olderCompletedTask, runningTask, recentFailedTask]

        let suggestedIDs = service.inactiveTasksForContinuationSuggestions().map(\.id)

        #expect(suggestedIDs == ["recent-failed", "older-completed"])
    }

    @Test
    @MainActor
    func materializeTaskReferencesBuildsReferenceBundleAndAncestorSummary() throws {
        let fm = FileManager.default
        let unique = UUID().uuidString
        let vmId = "test-vm-\(unique)"
        let directSessionId = "direct-session-\(unique)"
        let ancestorSessionId = "ancestor-session-\(unique)"
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("HivecrewTests-\(unique)", isDirectory: true)

        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: tempRoot)
            try? fm.removeItem(at: AppPaths.vmBundlePath(id: vmId))
            try? fm.removeItem(at: AppPaths.sessionDirectory(id: directSessionId))
            try? fm.removeItem(at: AppPaths.sessionDirectory(id: ancestorSessionId))
        }

        let attachmentURL = tempRoot.appendingPathComponent("brief.txt")
        try "brief".write(to: attachmentURL, atomically: true, encoding: .utf8)

        let outputURL = tempRoot.appendingPathComponent("report.md")
        try "report".write(to: outputURL, atomically: true, encoding: .utf8)

        let workspaceFileURL = AppPaths.sessionWorkspaceDirectory(id: directSessionId)
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("notes.txt")
        try fm.createDirectory(at: workspaceFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "scratch".write(to: workspaceFileURL, atomically: true, encoding: .utf8)

        try writeTraceSummary("Direct trace summary", sessionId: directSessionId)
        try writeTraceSummary("Ancestor trace summary", sessionId: ancestorSessionId)

        let now = Date()
        let ancestorTask = makeTask(
            id: "ancestor-\(unique)",
            title: "Prior analysis",
            taskDescription: "Summarize the research",
            status: .completed,
            createdAt: now.addingTimeInterval(-500),
            completedAt: now.addingTimeInterval(-450),
            sessionId: ancestorSessionId,
            resultSummary: "Ancestor result summary"
        )
        let directTask = makeTask(
            id: "direct-\(unique)",
            title: "Draft report",
            taskDescription: "Write the report",
            status: .completed,
            createdAt: now.addingTimeInterval(-300),
            completedAt: now.addingTimeInterval(-100),
            sessionId: directSessionId,
            attachmentInfos: [AttachmentInfo(
                originalPath: attachmentURL.path,
                copiedPath: nil,
                fileSize: 5
            )],
            outputFilePaths: [outputURL.path],
            referencedTaskIds: [ancestorTask.id],
            retrievalInlineContextBlocks: ["Remember the earlier numbers."],
            resultSummary: "Direct result summary"
        )
        let followUpTask = makeTask(
            id: "follow-up-\(unique)",
            title: "Follow-up",
            taskDescription: "Continue the work",
            status: .queued,
            createdAt: now,
            referencedTaskIds: [directTask.id]
        )

        let service = TaskService()
        service.tasks = [followUpTask, directTask, ancestorTask]

        let contextBlocks = try service.materializeTaskReferences(for: followUpTask, vmId: vmId)

        #expect(contextBlocks.count == 1)
        #expect(contextBlocks[0].contains("~/Desktop/workspace/references/"))
        #expect(contextBlocks[0].contains("Draft report"))

        let referencesRoot = AppPaths.vmWorkspaceDirectory(id: vmId)
            .appendingPathComponent("references", isDirectory: true)
        let bundles = try fm.contentsOfDirectory(
            at: referencesRoot,
            includingPropertiesForKeys: nil
        )

        #expect(bundles.count == 1)

        let bundleRoot = try #require(bundles.first)
        let contextURL = bundleRoot.appendingPathComponent("context.md")
        let context = try String(contentsOf: contextURL, encoding: .utf8)

        #expect(fm.fileExists(atPath: bundleRoot.appendingPathComponent("inbox/brief.txt").path))
        #expect(fm.fileExists(atPath: bundleRoot.appendingPathComponent("outbox/report.md").path))
        #expect(fm.fileExists(atPath: bundleRoot.appendingPathComponent("workspace/nested/notes.txt").path))

        #expect(context.contains("## Original Prompt"))
        #expect(context.contains("Write the report"))
        #expect(context.contains("## Injected Prompts"))
        #expect(context.contains("Remember the earlier numbers."))
        #expect(context.contains("## Result Summary"))
        #expect(context.contains("Direct result summary"))
        #expect(context.contains("## Session Trace Summary"))
        #expect(context.contains("Direct trace summary"))
        #expect(context.contains("## Referenced Ancestors"))
        #expect(context.contains("Prior analysis"))
        #expect(context.contains("Ancestor result summary"))
        #expect(context.contains("Ancestor trace summary"))
    }

    @Test
    @MainActor
    func persistWorkspaceSnapshotCopiesNestedDirectoriesAndReplacesOlderSnapshot() throws {
        let fm = FileManager.default
        let unique = UUID().uuidString
        let vmId = "workspace-vm-\(unique)"
        let sessionId = "workspace-session-\(unique)"
        let sourceFile = AppPaths.vmWorkspaceDirectory(id: vmId)
            .appendingPathComponent("drafts", isDirectory: true)
            .appendingPathComponent("draft.txt")
        let staleFile = AppPaths.sessionWorkspaceDirectory(id: sessionId)
            .appendingPathComponent("stale.txt")

        defer {
            try? fm.removeItem(at: AppPaths.vmBundlePath(id: vmId))
            try? fm.removeItem(at: AppPaths.sessionDirectory(id: sessionId))
        }

        try fm.createDirectory(at: sourceFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "fresh".write(to: sourceFile, atomically: true, encoding: .utf8)

        try fm.createDirectory(at: staleFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "old".write(to: staleFile, atomically: true, encoding: .utf8)

        let service = TaskService()
        service.persistWorkspaceSnapshot(vmId: vmId, sessionId: sessionId)

        let persistedFile = AppPaths.sessionWorkspaceDirectory(id: sessionId)
            .appendingPathComponent("drafts/draft.txt")

        #expect(fm.fileExists(atPath: persistedFile.path))
        #expect(!fm.fileExists(atPath: staleFile.path))
        #expect(try String(contentsOf: persistedFile, encoding: .utf8) == "fresh")
    }

    @Test
    func googleSearchReturnsResultsForThreeQueries() async throws {
        let queries = [
            "Swift programming language",
            "Apple developer documentation",
            "OpenAI API"
        ]

        for query in queries {
            let results = try await GoogleSearchClient.search(
                query: query,
                resultCount: 5
            )

            #expect(results.count > 0, "Expected Google results for query: \(query)")
        }
    }

    @Test
    func duckDuckGoSearchReturnsResultsForThreeQueries() async throws {
        let queries = [
            "Swift programming language",
            "Apple developer documentation",
            "OpenAI API"
        ]

        for query in queries {
            let results = try await DuckDuckGoSearch.search(
                query: query,
                resultCount: 5
            )

            #expect(results.count > 0, "Expected DuckDuckGo results for query: \(query)")
        }
    }

    @Test
    func webSearchServiceFallsBackFromSearchAPIToDuckDuckGo() async {
        let expected = SearchResult(
            url: "https://example.com/result",
            title: "Fallback Result",
            snippet: "Fallback snippet"
        )

        let execution = await WebSearchService.search(
            query: "fallback query",
            resultCount: 5,
            primaryEngine: "searchapi"
        ) { engine, _, _, _, _, _ in
            switch engine {
            case "searchapi":
                return []
            case "duckduckgo":
                return [expected]
            default:
                return []
            }
        }

        #expect(execution.results.count == 1)
        #expect(execution.results[0].url == expected.url)
        #expect(execution.notes.contains("Retried with duckduckgo."))
    }
}

private extension HivecrewTests {
    func makeTask(
        id: String,
        title: String,
        taskDescription: String,
        status: TaskStatus,
        createdAt: Date,
        completedAt: Date? = nil,
        sessionId: String? = nil,
        attachmentInfos: [AttachmentInfo]? = nil,
        outputFilePaths: [String]? = nil,
        referencedTaskIds: [String]? = nil,
        retrievalInlineContextBlocks: [String] = [],
        resultSummary: String? = nil
    ) -> TaskRecord {
        TaskRecord(
            id: id,
            title: title,
            taskDescription: taskDescription,
            status: status,
            createdAt: createdAt,
            completedAt: completedAt,
            sessionId: sessionId,
            providerId: "provider",
            modelId: "model",
            resultSummary: resultSummary,
            attachmentInfos: attachmentInfos,
            outputFilePaths: outputFilePaths,
            referencedTaskIds: referencedTaskIds,
            retrievalInlineContextBlocks: retrievalInlineContextBlocks
        )
    }

    func writeTraceSummary(_ summary: String, sessionId: String) throws {
        let sessionDirectory = AppPaths.sessionDirectory(id: sessionId)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)

        let line = """
        {"type":"session_end","data":{"sessionEnd":{"_0":{"summary":"\(summary)"}}}}
        """
        try (line + "\n").write(
            to: sessionDirectory.appendingPathComponent("trace.jsonl"),
            atomically: true,
            encoding: .utf8
        )
    }
}
