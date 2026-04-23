//
//  HivecrewTests.swift
//  HivecrewTests
//
//  Created by John Bean on 1/10/26.
//

import Foundation
import HivecrewAPI
import HivecrewAgentProtocol
import HivecrewCore
import HivecrewLLM
import HivecrewShared
import SwiftData
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
    func providerOrderingPrefersSortOrderThenName() {
        let later = LLMProviderRecord(
            id: "later",
            displayName: "Zed",
            sortOrder: 2,
            createdAt: .distantPast
        )
        let first = LLMProviderRecord(
            id: "first",
            displayName: "Beta",
            sortOrder: 0,
            createdAt: .distantPast
        )
        let tieBreaker = LLMProviderRecord(
            id: "tie-breaker",
            displayName: "Alpha",
            sortOrder: 0,
            createdAt: .distantFuture
        )

        let orderedIDs = orderedProviderRecords([later, first, tieBreaker]).map(\.id)

        #expect(orderedIDs == ["tie-breaker", "first", "later"])
        #expect(nextProviderSortOrder(in: [later, first, tieBreaker]) == 3)
    }

    @Test
    func imageGenerationRequestOptionsParseCamelAndSnakeCase() {
        let camelCase = ImageGenerationRequestOptions.fromToolArgs([
            "referenceImagePaths": ["/tmp/a.png"],
            "aspectRatio": "16:9"
        ])
        #expect(camelCase.referenceImagePaths == ["/tmp/a.png"])
        #expect(camelCase.aspectRatio == "16:9")

        let snakeCase = ImageGenerationRequestOptions.fromToolArgs([
            "reference_image_paths": ["/tmp/b.png"],
            "aspect_ratio": "4:5"
        ])
        #expect(snakeCase.referenceImagePaths == ["/tmp/b.png"])
        #expect(snakeCase.aspectRatio == "4:5")
    }

    @Test
    func codexOAuthImageSizeMapsSupportedAspectRatios() {
        #expect(codexOAuthImageSize(for: nil) == nil)
        #expect(codexOAuthImageSize(for: "1:1") == "1024x1024")
        #expect(codexOAuthImageSize(for: "2:3") == "1024x1536")
        #expect(codexOAuthImageSize(for: "3:2") == "1536x1024")
        #expect(codexOAuthImageSize(for: "3:4") == "768x1024")
        #expect(codexOAuthImageSize(for: "4:3") == "1024x768")
        #expect(codexOAuthImageSize(for: "4:5") == "1024x1280")
        #expect(codexOAuthImageSize(for: "5:4") == "1280x1024")
        #expect(codexOAuthImageSize(for: "9:16") == "720x1280")
        #expect(codexOAuthImageSize(for: "16:9") == "1280x720")
        #expect(codexOAuthImageSize(for: "21:9") == "1680x720")
    }

    @Test
    func onlyGenerateImageIsMarkedParallelizableAmongHostSideTools() {
        #expect(AgentMethod.generateImage.isHostSideTool)
        #expect(AgentMethod.generateImage.isParallelizableHostSideTool)
        #expect(AgentMethod.webSearch.isHostSideTool)
        #expect(!AgentMethod.webSearch.isParallelizableHostSideTool)
        #expect(!AgentMethod.runShell.isParallelizableHostSideTool)
    }
    
    @Test
    func taskRecordRecognizesRemoteOnlyProviderPrefix() {
        let remoteTask = TaskRecord(
            title: "Remote only",
            taskDescription: "Run remotely",
            providerId: "\(TaskRecord.remoteOnlyProviderPrefix)OpenRouter",
            modelId: "model"
        )
        let localTask = TaskRecord(
            title: "Local",
            taskDescription: "Run locally",
            providerId: "provider",
            modelId: "model"
        )
        
        #expect(remoteTask.requiresRemoteClusterExecution)
        #expect(!localTask.requiresRemoteClusterExecution)
    }

    @Test
    @MainActor
    func internalClusterExecutionsRemainVisibleDuringStartupAndShortlyAfterCompletionInEnvironmentsOnly() {
        let now = Date()
        let service = TaskService()
        let staleCompletionOffset = TaskService.internalClusterExecutionVisibilityGraceInterval + 10

        let waitingTask = TaskRecord(
            title: "Leased waiting task",
            taskDescription: "Waiting for VM",
            status: .waitingForVM,
            createdAt: now.addingTimeInterval(-30),
            providerId: "provider",
            modelId: "model",
            clusterOwnerTaskId: "canonical-owner-task"
        )

        let recentCompletedTask = TaskRecord(
            title: "Leased completed task",
            taskDescription: "Completed recently",
            status: .completed,
            createdAt: now.addingTimeInterval(-120),
            startedAt: now.addingTimeInterval(-90),
            completedAt: now.addingTimeInterval(-30),
            providerId: "provider",
            modelId: "model",
            clusterOwnerTaskId: "canonical-owner-task-2"
        )

        let staleCompletedTask = TaskRecord(
            title: "Old leased completed task",
            taskDescription: "Completed a while ago",
            status: .completed,
            createdAt: now.addingTimeInterval(-600),
            startedAt: now.addingTimeInterval(-580),
            completedAt: now.addingTimeInterval(-staleCompletionOffset),
            providerId: "provider",
            modelId: "model",
            clusterOwnerTaskId: "canonical-owner-task-3"
        )

        #expect(service.shouldShowInAgentEnvironments(waitingTask, now: now))
        #expect(service.shouldShowInAgentPreview(waitingTask, now: now))

        #expect(service.shouldKeepInternalClusterExecutionVisible(recentCompletedTask, now: now))
        #expect(service.shouldShowInAgentEnvironments(recentCompletedTask, now: now))
        #expect(!service.shouldShowInAgentPreview(recentCompletedTask, now: now))

        #expect(!service.shouldKeepInternalClusterExecutionVisible(staleCompletedTask, now: now))
        #expect(!service.shouldShowInAgentEnvironments(staleCompletedTask, now: now))
        #expect(!service.shouldShowInAgentPreview(staleCompletedTask, now: now))
    }

    @Test
    @MainActor
    func agentPreviewHidesInternalClusterExecutionWhenLiveStateIsTerminal() {
        let service = TaskService()
        let task = TaskRecord(
            title: "Leased running task",
            taskDescription: "Live state finished first",
            status: .running,
            providerId: "provider",
            modelId: "model",
            clusterOwnerTaskId: "canonical-owner-task"
        )
        let publisher = AgentStatePublisher(taskId: task.id)
        publisher.status = .completed
        service.statePublishers[task.id] = publisher

        #expect(!service.shouldShowInAgentPreview(task))
        #expect(!service.shouldShowInAgentEnvironments(task))
    }
    
    @Test
    func remoteTaskIndexMapsCanonicalAndWorkerTaskIDs() async {
        let index = RemoteTaskIndex()
        let task = APITask(
            id: "canonical-task",
            title: "Cluster task",
            description: "Run something",
            status: .running,
            providerName: "Provider",
            modelId: "model",
            createdAt: Date()
        )
        
        await index.register(
            canonicalTaskId: "canonical-task",
            peerId: "peer-1",
            workerTaskId: "worker-task-42",
            task: task
        )
        
        #expect(await index.peerId(for: "canonical-task") == "peer-1")
        #expect(await index.workerTaskId(for: "canonical-task") == "worker-task-42")
        #expect(await index.canonicalTaskId(peerId: "peer-1", workerTaskId: "worker-task-42") == "canonical-task")
        
        await index.remove(canonicalTaskId: "canonical-task")
        #expect(await index.peerId(for: "canonical-task") == nil)
        #expect(await index.canonicalTaskId(peerId: "peer-1", workerTaskId: "worker-task-42") == nil)
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
    func federatedLocalTargetStartsImmediatelyInsteadOfRemainingQueued() async throws {
        UserDefaults.standard.set("worker-provider", forKey: "workerModelProviderId")
        UserDefaults.standard.set("worker-model", forKey: "workerModelId")
        UserDefaults.standard.set("dummy-template", forKey: "defaultTemplateId")
        defer {
            UserDefaults.standard.removeObject(forKey: "workerModelProviderId")
            UserDefaults.standard.removeObject(forKey: "workerModelId")
            UserDefaults.standard.removeObject(forKey: "defaultTemplateId")
        }

        let schema = Schema([
            VMRecord.self,
            LLMProviderRecord.self,
            TaskRecord.self,
            AgentSessionRecord.self,
            ScheduledTask.self,
            MCPServerRecord.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext

        let localProviderRecord = LLMProviderRecord(
            id: "provider-local",
            displayName: "Local Provider",
            isDefault: true
        )
        context.insert(localProviderRecord)
        try context.save()

        let taskService = TaskService()
        taskService.setModelContext(context)

        let localProvider = APIServiceProviderBridge(
            taskService: taskService,
            schedulerService: SchedulerService.shared,
            vmServiceClient: VMServiceClient.shared,
            modelContext: context,
            fileStorage: TaskFileStorage()
        )
        let federatedProvider = FederatedServiceProvider(
            localProvider: localProvider,
            clusterManager: ClusterManager.shared,
            remoteTaskIndex: RemoteTaskIndex()
        )

        let createdTask = try await federatedProvider.createTask(
            description: "Run this locally",
            providerName: localProviderRecord.displayName,
            modelId: "test-model",
            executionTarget: .local,
            reasoningEnabled: nil,
            reasoningEffort: nil,
            attachedFilePaths: [],
            outputDirectory: nil,
            planFirst: false,
            mentionedSkillNames: [],
            referencedTaskIds: [],
            continuationSourceTaskId: nil,
            contextPackId: nil,
            contextSuggestionIds: [],
            contextModeOverrides: [:],
            contextInlineBlocks: [],
            contextAttachmentPaths: []
        )

        #expect(createdTask.status != .queued)
        let persistedTask = try #require(taskService.tasks.first(where: { $0.id == createdTask.id }))
        #expect(persistedTask.status != .queued)
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
    @MainActor
    func restoreTransferredTaskReferencesRebuildsNestedReferenceBundles() throws {
        let fm = FileManager.default
        let unique = UUID().uuidString
        let ownerRoot = fm.temporaryDirectory.appendingPathComponent("HivecrewReferenceOwner-\(unique)", isDirectory: true)
        let referencesRoot = ownerRoot.appendingPathComponent("references", isDirectory: true)
        let vmId = "reference-restore-vm-\(unique)"

        defer {
            try? fm.removeItem(at: ownerRoot)
            try? fm.removeItem(at: AppPaths.vmBundlePath(id: vmId))
        }

        let contextFile = referencesRoot
            .appendingPathComponent("draft-report/context.md")
        let workspaceFile = referencesRoot
            .appendingPathComponent("draft-report/workspace/nested/notes.txt")
        let inboxFile = referencesRoot
            .appendingPathComponent("draft-report/inbox/brief.txt")

        try fm.createDirectory(at: contextFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: workspaceFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: inboxFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "context".write(to: contextFile, atomically: true, encoding: .utf8)
        try "notes".write(to: workspaceFile, atomically: true, encoding: .utf8)
        try "brief".write(to: inboxFile, atomically: true, encoding: .utf8)

        let stagedFiles = [contextFile, workspaceFile, inboxFile].map { fileURL in
            ClusterReferenceFile(
                relativePath: fileURL.path.replacingOccurrences(of: referencesRoot.path + "/", with: ""),
                stagedPath: fileURL.path
            )
        }

        let service = TaskService()
        try service.restoreTransferredTaskReferences(vmId: vmId, referenceFiles: stagedFiles)

        let restoredRoot = AppPaths.vmWorkspaceDirectory(id: vmId)
            .appendingPathComponent("references", isDirectory: true)
        #expect(fm.fileExists(atPath: restoredRoot.appendingPathComponent("draft-report/context.md").path))
        #expect(fm.fileExists(atPath: restoredRoot.appendingPathComponent("draft-report/workspace/nested/notes.txt").path))
        #expect(fm.fileExists(atPath: restoredRoot.appendingPathComponent("draft-report/inbox/brief.txt").path))
        #expect(try String(contentsOf: restoredRoot.appendingPathComponent("draft-report/workspace/nested/notes.txt"), encoding: .utf8) == "notes")
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

    @Test
    func remoteOnlyTaskDispatchesEvenWhenLocalSlotsAreAvailable() {
        #expect(
            FederatedServiceProvider.shouldDispatchRemotely(
                requiresRemoteClusterExecution: true,
                localAvailableSlots: 2
            )
        )
    }

    @Test
    func localTaskStaysLocalWhenCapacityIsAvailable() {
        #expect(
            !FederatedServiceProvider.shouldDispatchRemotely(
                requiresRemoteClusterExecution: false,
                localAvailableSlots: 1
            )
        )
    }

    @Test
    func localTaskDispatchesWhenNoLocalCapacityRemains() {
        #expect(
            FederatedServiceProvider.shouldDispatchRemotely(
                requiresRemoteClusterExecution: false,
                localAvailableSlots: 0
            )
        )
    }

    @Test
    func localTaskDispatchesWhenLocalCapacityCannotBeRead() {
        #expect(
            FederatedServiceProvider.shouldDispatchRemotely(
                requiresRemoteClusterExecution: false,
                localAvailableSlots: nil
            )
        )
    }

    @Test
    func selectBestPeerPrefersManualOrderWhenPeerSupportsModel() {
        let peers = [
            makePeer(id: "peer-a", availableSlots: 1, providers: [provider("OpenAI", ["gpt-5"])]),
            makePeer(id: "peer-b", availableSlots: 4, providers: [provider("OpenAI", ["gpt-5"])])
        ]

        let selected = ClusterManager.selectBestPeer(
            from: peers,
            preferredOrder: ["peer-a", "peer-b"],
            providerName: "OpenAI",
            modelId: "gpt-5"
        )

        #expect(selected?.id == "peer-a")
    }

    @Test
    func selectBestPeerSkipsPreferredPeerWhenRequestedModelIsMissing() {
        let peers = [
            makePeer(id: "peer-a", availableSlots: 3, providers: [provider("OpenAI", ["gpt-4.1"])]),
            makePeer(id: "peer-b", availableSlots: 1, providers: [provider("OpenAI", ["gpt-5"])])
        ]

        let selected = ClusterManager.selectBestPeer(
            from: peers,
            preferredOrder: ["peer-a", "peer-b"],
            providerName: "OpenAI",
            modelId: "gpt-5"
        )

        #expect(selected?.id == "peer-b")
    }

    @Test
    func selectBestPeerIgnoresOfflinePeers() {
        let peers = [
            makePeer(id: "peer-a", status: .offline, availableSlots: 8, providers: [provider("OpenAI", ["gpt-5"])]),
            makePeer(id: "peer-b", availableSlots: 1, providers: [provider("OpenAI", ["gpt-5"])])
        ]

        let selected = ClusterManager.selectBestPeer(
            from: peers,
            preferredOrder: [],
            providerName: "OpenAI",
            modelId: "gpt-5"
        )

        #expect(selected?.id == "peer-b")
    }

    @Test
    func selectBestPeerIgnoresPeersWithoutFreeSlots() {
        let peers = [
            makePeer(id: "peer-a", availableSlots: 0, providers: [provider("OpenAI", ["gpt-5"])]),
            makePeer(id: "peer-b", availableSlots: 2, providers: [provider("OpenAI", ["gpt-5"])])
        ]

        let selected = ClusterManager.selectBestPeer(
            from: peers,
            preferredOrder: [],
            providerName: "OpenAI",
            modelId: "gpt-5"
        )

        #expect(selected?.id == "peer-b")
    }

    @Test
    func selectBestPeerFallsBackToHighestCapacityWhenNoPreferenceApplies() {
        let peers = [
            makePeer(id: "peer-a", availableSlots: 1, providers: [provider("OpenAI", ["gpt-5"])]),
            makePeer(id: "peer-b", availableSlots: 5, providers: [provider("OpenAI", ["gpt-5"])])
        ]

        let selected = ClusterManager.selectBestPeer(
            from: peers,
            preferredOrder: [],
            providerName: "OpenAI",
            modelId: "gpt-5"
        )

        #expect(selected?.id == "peer-b")
    }

    @Test
    func selectBestPeerHonorsExcludingSetAcrossRetries() {
        let peers = [
            makePeer(id: "peer-a", availableSlots: 5, providers: [provider("OpenAI", ["gpt-5"])]),
            makePeer(id: "peer-b", availableSlots: 2, providers: [provider("OpenAI", ["gpt-5"])])
        ]

        let selected = ClusterManager.selectBestPeer(
            from: peers,
            preferredOrder: [],
            providerName: "OpenAI",
            modelId: "gpt-5",
            excluding: ["peer-a"]
        )

        #expect(selected?.id == "peer-b")
    }

    @Test
    func peerCapabilityIsUnknownWithoutFetchedCapabilities() {
        let peer = makePeer(id: "peer-a", availableSlots: 1, providers: [])
        #expect(peer.capabilityMatch(providerName: "OpenAI", modelId: "gpt-5") == .unknown)
    }

    @Test
    func peerCapabilityIsUnknownWhenProviderModelsHaveNotBeenEnumerated() {
        let peer = makePeer(id: "peer-a", availableSlots: 1, providers: [provider("OpenAI", [])])
        #expect(peer.capabilityMatch(providerName: "OpenAI", modelId: "gpt-5") == .unknown)
    }

    @Test
    func peerCapabilityIsUnsupportedWhenProviderIsMissing() {
        let peer = makePeer(id: "peer-a", availableSlots: 1, providers: [provider("Anthropic", ["claude-sonnet-4.5"])])
        #expect(peer.capabilityMatch(providerName: "OpenAI", modelId: "gpt-5") == .unsupported)
    }

    @Test
    func peerCapabilityIsUnsupportedWhenModelIsMissingFromProvider() {
        let peer = makePeer(id: "peer-a", availableSlots: 1, providers: [provider("OpenAI", ["gpt-4.1"])])
        #expect(peer.capabilityMatch(providerName: "OpenAI", modelId: "gpt-5") == .unsupported)
    }

    @Test
    func peerCapabilityIsSupportedWhenProviderAdvertisesSelectedModel() {
        let peer = makePeer(id: "peer-a", availableSlots: 1, providers: [provider("OpenAI", ["gpt-5"])])
        #expect(peer.capabilityMatch(providerName: "OpenAI", modelId: "gpt-5") == .supported)
    }

    @Test
    func distributionChoosesOnlyPeerAdvertisingSelectedModelWhenPeersDiffer() {
        let peers = [
            makePeer(id: "peer-a", availableSlots: 5, providers: [provider("OpenAI", ["gpt-4.1"])]),
            makePeer(id: "peer-b", availableSlots: 1, providers: [provider("OpenAI", ["gpt-5"])]),
            makePeer(id: "peer-c", availableSlots: 10, providers: [provider("Anthropic", ["claude-sonnet-4.5"])])
        ]

        let selected = ClusterManager.selectBestPeer(
            from: peers,
            preferredOrder: ["peer-a", "peer-c", "peer-b"],
            providerName: "OpenAI",
            modelId: "gpt-5"
        )

        #expect(selected?.id == "peer-b")
    }

    @Test
    func fiveNodeClusterSkipsUnsupportedPeersUntilFirstCompatiblePreferredPeer() {
        let peers = [
            makePeer(id: "peer-a", availableSlots: 8, providers: [provider("OpenAI", ["gpt-4.1"])]),
            makePeer(id: "peer-b", availableSlots: 7, providers: [provider("Anthropic", ["claude-sonnet-4.5"])]),
            makePeer(id: "peer-c", availableSlots: 2, providers: [provider("OpenAI", ["gpt-5"])]),
            makePeer(id: "peer-d", availableSlots: 9, providers: [provider("OpenAI", ["gpt-5"])]),
            makePeer(id: "peer-e", availableSlots: 6, providers: [provider("OpenAI", ["gpt-4.1", "gpt-5"])])
        ]

        let selected = ClusterManager.selectBestPeer(
            from: peers,
            preferredOrder: ["peer-a", "peer-b", "peer-c", "peer-d", "peer-e"],
            providerName: "OpenAI",
            modelId: "gpt-5"
        )

        #expect(selected?.id == "peer-c")
    }

    @Test
    func fiveNodeClusterFallsBackToHighestCapacityAmongCompatiblePeersWhenNoOrderMatches() {
        let peers = [
            makePeer(id: "peer-a", availableSlots: 3, providers: [provider("OpenAI", ["gpt-4.1"])]),
            makePeer(id: "peer-b", availableSlots: 4, providers: [provider("OpenAI", ["gpt-5"])]),
            makePeer(id: "peer-c", availableSlots: 6, providers: [provider("OpenAI", ["gpt-5"])]),
            makePeer(id: "peer-d", availableSlots: 2, providers: [provider("Anthropic", ["claude-sonnet-4.5"])]),
            makePeer(id: "peer-e", availableSlots: 5, providers: [provider("OpenAI", ["gpt-5"])])
        ]

        let selected = ClusterManager.selectBestPeer(
            from: peers,
            preferredOrder: ["peer-z"],
            providerName: "OpenAI",
            modelId: "gpt-5"
        )

        #expect(selected?.id == "peer-c")
    }

    @Test
    func fiveNodeClusterRetrySelectsNextCompatiblePeerAfterExcludingEarlierChoices() {
        let peers = [
            makePeer(id: "peer-a", availableSlots: 5, providers: [provider("OpenAI", ["gpt-5"])]),
            makePeer(id: "peer-b", availableSlots: 4, providers: [provider("OpenAI", ["gpt-5"])]),
            makePeer(id: "peer-c", availableSlots: 3, providers: [provider("OpenAI", ["gpt-4.1"])]),
            makePeer(id: "peer-d", availableSlots: 2, providers: [provider("OpenAI", ["gpt-5"])]),
            makePeer(id: "peer-e", availableSlots: 1, providers: [provider("Anthropic", ["claude-sonnet-4.5"])])
        ]

        let selected = ClusterManager.selectBestPeer(
            from: peers,
            preferredOrder: ["peer-a", "peer-b", "peer-c", "peer-d", "peer-e"],
            providerName: "OpenAI",
            modelId: "gpt-5",
            excluding: ["peer-a", "peer-b"]
        )

        #expect(selected?.id == "peer-d")
    }

    @Test
    func voiceRecoveryPolicyDefersFreshRestartWhileSuspended() {
        let decision = VoiceRecoveryPolicy.decideNextStep(
            callState: .suspended,
            hasUsedFreshRestartInCurrentFailureEpisode: false
        )

        #expect(decision == .deferUntilResume)
    }

    @Test
    func voiceRecoveryPolicyFailsAfterFreshRestartWasAlreadyUsed() {
        let decision = VoiceRecoveryPolicy.decideNextStep(
            callState: .active,
            hasUsedFreshRestartInCurrentFailureEpisode: true
        )

        #expect(decision == .terminalFailure)
    }

    @Test
    func transcriptReplaySerializerPreservesVisibleConversationOrder() {
        let entries: [TranscriptEntry] = [
            .speech(role: .user, text: "First request"),
            .speech(role: .model, text: "First response"),
            .toolUse(
                ToolUseRecord(
                    toolName: "search_files",
                    summary: "Found the project files",
                    detail: "Returned two matching folders",
                    fileResults: [
                        VoiceFileSearchResult(
                            id: "result-1",
                            title: "project",
                            path: "/tmp/project",
                            sourceType: "file",
                            relevanceScore: 0.99
                        )
                    ],
                    previewFilePath: nil
                )
            ),
            .speech(role: .user, text: "Second request")
        ]

        let chunks = VoiceTranscriptReplaySerializer.serialize(entries: entries)
        let flattened = chunks.joined(separator: "\n")

        #expect(flattened.contains("User: First request"))
        #expect(flattened.contains("Assistant: First response"))
        #expect(flattened.contains("Tool search_files: Found the project files"))
        #expect(flattened.contains("Selected files:\n/tmp/project"))
        #expect(flattened.contains("User: Second request"))
    }

    @Test
    func transcriptReplaySerializerSplitsLargeTranscriptDeterministically() {
        let longText = String(repeating: "A", count: 2_600)
        let entries: [TranscriptEntry] = [
            .speech(role: .user, text: longText)
        ]

        let chunks = VoiceTranscriptReplaySerializer.serialize(entries: entries)

        #expect(chunks.count > 1)
        #expect(chunks.joined() == "User: " + longText)
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

    func makePeer(
        id: String,
        status: PeerStatus = .online,
        availableSlots: Int,
        providers: [PeerProviderSummary]
    ) -> PeerNode {
        PeerNode(
            id: id,
            subdomain: id,
            name: id,
            tunnelUrl: "https://\(id).hivecrew.org",
            status: status,
            availableSlots: availableSlots,
            runningTasks: 0,
            queuedTasks: 0,
            lastSeen: Date(),
            providers: providers
        )
    }

    func provider(_ name: String, _ modelIds: [String]) -> PeerProviderSummary {
        PeerProviderSummary(providerName: name, modelIds: modelIds)
    }
}
