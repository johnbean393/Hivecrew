import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers
import XCTest
import ZIPFoundation
@testable import HivecrewRetrievalCore
import HivecrewRetrievalProtocol

final class RetrievalExtractionTests: XCTestCase {
    func testIndexingPolicySkipsCodeAndDependencyDirectories() throws {
        let root = URL(fileURLWithPath: "/tmp/hivecrew-policy-root", isDirectory: true)
        let policy = IndexingPolicy.preset(profile: "developer", startupAllowlistRoots: [root.path])
        let now = Date()

        let codeEval = policy.evaluate(
            fileURL: root.appendingPathComponent("src/app.swift"),
            fileSize: 128,
            modifiedAt: now
        )
        if case .skip(let reason) = codeEval {
            XCTAssertEqual(reason, "unsupported_file_type")
        } else {
            XCTFail("Expected code file to be skipped")
        }

        let dependencyEval = policy.evaluate(
            fileURL: root.appendingPathComponent("lib/python3.11/site-packages/demo/readme.txt"),
            fileSize: 128,
            modifiedAt: now
        )
        if case .skip(let reason) = dependencyEval {
            XCTAssertEqual(reason, "excluded_path")
        } else {
            XCTFail("Expected dependency path to be excluded")
        }

        let javaTargetEval = policy.evaluate(
            fileURL: root.appendingPathComponent("service/target/classes/report.txt"),
            fileSize: 128,
            modifiedAt: now
        )
        if case .skip(let reason) = javaTargetEval {
            XCTAssertEqual(reason, "excluded_path")
        } else {
            XCTFail("Expected Java target output path to be excluded")
        }

        let tsBuildEval = policy.evaluate(
            fileURL: root.appendingPathComponent("frontend/.next/server/chunk.txt"),
            fileSize: 128,
            modifiedAt: now
        )
        if case .skip(let reason) = tsBuildEval {
            XCTAssertEqual(reason, "excluded_path")
        } else {
            XCTFail("Expected TypeScript/Web build output path to be excluded")
        }

        let cmakeEval = policy.evaluate(
            fileURL: root.appendingPathComponent("native/cmake-build-debug/compile_commands.json"),
            fileSize: 128,
            modifiedAt: now
        )
        if case .skip(let reason) = cmakeEval {
            XCTAssertEqual(reason, "excluded_path")
        } else {
            XCTFail("Expected CMake build output path to be excluded")
        }
    }

    func testFileConnectorBackfillReportsScanDiagnosticsAndPrunesExcludedSubtrees() async throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let corpusRoot = scratch.appendingPathComponent("corpus", isDirectory: true)
        let includedDir = corpusRoot.appendingPathComponent("included", isDirectory: true)
        let excludedDir = corpusRoot.appendingPathComponent("node_modules/deep/tree", isDirectory: true)
        try FileManager.default.createDirectory(at: includedDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: excludedDir, withIntermediateDirectories: true)

        try "included token".write(
            to: includedDir.appendingPathComponent("include.txt"),
            atomically: true,
            encoding: .utf8
        )
        for idx in 0..<120 {
            try "excluded token \(idx)".write(
                to: excludedDir.appendingPathComponent("excluded-\(idx).txt"),
                atomically: true,
                encoding: .utf8
            )
        }

        let policy = IndexingPolicy.preset(profile: "developer", startupAllowlistRoots: [corpusRoot.path])
        let events = EventAccumulator()
        let scans = ScanStatsAccumulator()
        let connector = FileConnector(
            policy: policy,
            scanStatsHandler: { stats in
                await scans.append(stats)
            }
        )

        _ = try await connector.runBackfill(
            resumeToken: nil,
            mode: .full,
            policy: policy,
            limit: 500
        ) { batch, _ in
            await events.append(batch)
        }

        let received = await events.items()
        XCTAssertEqual(received.count, 1)
        XCTAssertTrue(received.allSatisfy { !$0.sourcePathOrHandle.contains("/node_modules/") })

        let stats = await scans.items()
        XCTAssertFalse(stats.isEmpty)
        let latest = try XCTUnwrap(stats.last)
        XCTAssertGreaterThan(latest.candidatesSkippedExcluded, 0)
        XCTAssertGreaterThanOrEqual(latest.candidatesSeen, latest.eventsEmitted)
    }

    func testFileConnectorBackfillEmitsEventsForExpandedFormats() async throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let corpusRoot = scratch.appendingPathComponent("corpus", isDirectory: true)
        try FileManager.default.createDirectory(at: corpusRoot, withIntermediateDirectories: true)
        _ = try createFixtures(at: corpusRoot)

        let policy = IndexingPolicy.preset(profile: "developer", startupAllowlistRoots: [corpusRoot.path])
        let connector = FileConnector(policy: policy)
        let accumulator = EventAccumulator()
        var checkpointResult: BackfillCheckpoint?

        checkpointResult = try await connector.runBackfill(
            resumeToken: nil,
            mode: .full,
            policy: policy,
            limit: 500
        ) { events, _ in
            await accumulator.append(events)
        }
        let received = await accumulator.items()

        XCTAssertGreaterThanOrEqual(received.count, 5)
        XCTAssertTrue(received.contains(where: { $0.title.contains("plan.docx") }))
        XCTAssertTrue(received.contains(where: { $0.title.contains("slides.pptx") }))
        XCTAssertTrue(received.contains(where: { $0.title.contains("budget.xlsx") }))
        XCTAssertTrue(received.contains(where: { $0.title.contains("whiteboard.png") }))
        XCTAssertTrue(received.contains(where: { $0.title.contains("output-file-map.json") }))
        XCTAssertEqual(checkpointResult?.status, "idle")
        XCTAssertEqual(checkpointResult?.itemsProcessed, received.count)
        XCTAssertEqual(checkpointResult?.estimatedTotal, received.count)
    }

    func testContentExtractionAcrossPopularFormats() async throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let corpusRoot = scratch.appendingPathComponent("corpus", isDirectory: true)
        try FileManager.default.createDirectory(at: corpusRoot, withIntermediateDirectories: true)
        let fixtures = try createFixtures(at: corpusRoot)

        let policy = IndexingPolicy.preset(profile: "developer", startupAllowlistRoots: [corpusRoot.path])
        let extractionService = ContentExtractionService()

        let docx = await extractionService.extract(fileURL: fixtures.docx, policy: policy)
        let pptx = await extractionService.extract(fileURL: fixtures.pptx, policy: policy)
        let xlsx = await extractionService.extract(fileURL: fixtures.xlsx, policy: policy)
        let image = await extractionService.extract(fileURL: fixtures.image, policy: policy)
        let pdf = await extractionService.extract(fileURL: fixtures.pdf, policy: policy)
        let json = await extractionService.extract(fileURL: fixtures.json, policy: policy)

        XCTAssertEqual(docx.telemetry.outcome, .success)
        XCTAssertTrue(docx.content?.text.localizedCaseInsensitiveContains("DOCX plan token") == true)

        XCTAssertEqual(pptx.telemetry.outcome, .success)
        XCTAssertTrue(pptx.content?.text.localizedCaseInsensitiveContains("PPTX launch token") == true)

        XCTAssertEqual(xlsx.telemetry.outcome, .success)
        XCTAssertTrue(xlsx.content?.text.localizedCaseInsensitiveContains("XLSX revenue token") == true)

        XCTAssertTrue(image.telemetry.usedOCR)
        XCTAssertNotNil(image.content)

        XCTAssertTrue(pdf.telemetry.usedOCR)
        XCTAssertNotNil(pdf.content)

        XCTAssertEqual(json.telemetry.outcome, .success)
        XCTAssertTrue(json.content?.text.localizedCaseInsensitiveContains("JSON hidden token") == true)
    }

    func testLegacyWordDocExtractionAndPolicySupport() async throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let corpusRoot = scratch.appendingPathComponent("corpus", isDirectory: true)
        try FileManager.default.createDirectory(at: corpusRoot, withIntermediateDirectories: true)
        let docURL = corpusRoot.appendingPathComponent("legacy.doc")
        try createLegacyWordDoc(with: "LEGACY DOC TOKEN", at: docURL)

        let policy = IndexingPolicy.preset(profile: "developer", startupAllowlistRoots: [corpusRoot.path])
        let attrs = try FileManager.default.attributesOfItem(atPath: docURL.path)
        let fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let evaluation = policy.evaluate(fileURL: docURL, fileSize: fileSize, modifiedAt: Date())
        switch evaluation {
        case .index, .deferred:
            break
        case .skip(let reason):
            XCTFail("Expected .doc to be indexable, got skip reason: \(reason)")
        }

        let extractionService = ContentExtractionService()
        let result = await extractionService.extract(fileURL: docURL, policy: policy)
        XCTAssertNotEqual(result.telemetry.outcome, .unsupported)
        XCTAssertTrue(result.content?.text.localizedCaseInsensitiveContains("LEGACY DOC TOKEN") == true)
    }

    func testStorePurgesOfficeDocumentsAndAttemptsForForcedReindex() async throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let paths = makePaths(root: scratch)
        for directory in [paths.daemonDirectory, paths.indexDirectory, paths.cacheDirectory, paths.contextPacksDirectory, paths.logsDirectory, paths.socketDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let store = RetrievalStore(dbPath: paths.metadataDBPath, contextPackDirectory: paths.contextPacksDirectory)
        try await store.openAndMigrate()

        let now = Date()
        let officeSourceID = "/tmp/report.docx"
        let textSourceID = "/tmp/notes.txt"

        let officeDocument = RetrievalDocument(
            id: "doc-office",
            sourceType: .file,
            sourceId: officeSourceID,
            title: "report.docx",
            body: "Office token",
            sourcePathOrHandle: officeSourceID,
            updatedAt: now,
            risk: .low,
            partition: "hot",
            searchable: true
        )
        let textDocument = RetrievalDocument(
            id: "doc-text",
            sourceType: .file,
            sourceId: textSourceID,
            title: "notes.txt",
            body: "Text token",
            sourcePathOrHandle: textSourceID,
            updatedAt: now,
            risk: .low,
            partition: "hot",
            searchable: true
        )

        try await store.upsertDocument(
            officeDocument,
            chunks: [
                RetrievalChunk(
                    id: "doc-office:0",
                    documentId: "doc-office",
                    text: "Office token",
                    index: 0,
                    embedding: [0.2, 0.4]
                )
            ]
        )
        try await store.upsertDocument(
            textDocument,
            chunks: [
                RetrievalChunk(
                    id: "doc-text:0",
                    documentId: "doc-text",
                    text: "Text token",
                    index: 0,
                    embedding: [0.1, 0.3]
                )
            ]
        )

        try await store.recordIngestionAttempt(
            sourceType: .file,
            sourceId: officeSourceID,
            sourcePathOrHandle: officeSourceID,
            updatedAt: now,
            outcome: .unsupported
        )
        try await store.recordIngestionAttempt(
            sourceType: .file,
            sourceId: textSourceID,
            sourcePathOrHandle: textSourceID,
            updatedAt: now,
            outcome: .unsupported
        )

        let removedCount = try await store.purgeFileDocumentsForExtensions(["doc", "docx"])
        XCTAssertEqual(removedCount, 1)
        let removedOfficeDocument = try await store.fetchDocument(for: "doc-office")
        let retainedTextDocument = try await store.fetchDocument(for: "doc-text")
        XCTAssertNil(removedOfficeDocument)
        XCTAssertNotNil(retainedTextDocument)

        let officeAttemptStillCurrent = try await store.isIngestionAttemptCurrent(
            sourceType: .file,
            sourceId: officeSourceID,
            updatedAt: now
        )
        XCTAssertFalse(officeAttemptStillCurrent)

        let textAttemptStillCurrent = try await store.isIngestionAttemptCurrent(
            sourceType: .file,
            sourceId: textSourceID,
            updatedAt: now
        )
        XCTAssertTrue(textAttemptStillCurrent)
    }

    func testContentExtractionTimeoutRemainsResponsiveWhenWorkQueueIsBlocked() async throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let fileURL = scratch.appendingPathComponent("timeout-test.bin")
        try Data("block".utf8).write(to: fileURL)

        let extractionQueue = DispatchQueue(label: "test.retrieval.extraction.blocked")
        let extractionService = ContentExtractionService(
            extractors: [BlockingTimeoutTestExtractor(delaySeconds: 1.5)],
            scheduleExtraction: { work in
                extractionQueue.async(execute: work)
            },
            scheduleTimeout: { timeoutSeconds, timeout in
                Thread.detachNewThread {
                    Thread.sleep(forTimeInterval: timeoutSeconds)
                    timeout()
                }
            }
        )
        let policy = IndexingPolicy(
            allowlistRoots: [scratch.path],
            excludes: [],
            allowedFileExtensions: ["bin"],
            skipUnknownMime: false,
            maxExtractionSecondsPerFile: 0.15
        )

        let start = Date()
        let result = await extractionService.extract(fileURL: fileURL, policy: policy)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(result.telemetry.outcome, .partial)
        XCTAssertEqual(result.telemetry.detail, "timeout")
        XCTAssertEqual(result.content?.title, "timeout-test.bin")
        XCTAssertTrue(result.content?.warnings.contains("extraction_timeout_metadata_only") == true)
        XCTAssertLessThan(elapsed, 0.8)
    }

    func testContentExtractionTimeoutSurvivesManyConcurrentBlockedExtractions() async throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let fileURL = scratch.appendingPathComponent("timeout-load-test.bin")
        try Data("block".utf8).write(to: fileURL)

        let extractionService = ContentExtractionService(
            extractors: [BlockingTimeoutTestExtractor(delaySeconds: 1.5)],
            scheduleExtraction: { work in
                Thread.detachNewThread {
                    work()
                }
            },
            scheduleTimeout: { timeoutSeconds, timeout in
                Thread.detachNewThread {
                    Thread.sleep(forTimeInterval: timeoutSeconds)
                    timeout()
                }
            }
        )
        let policy = IndexingPolicy(
            allowlistRoots: [scratch.path],
            excludes: [],
            allowedFileExtensions: ["bin"],
            skipUnknownMime: false,
            maxExtractionSecondsPerFile: 0.15
        )

        let start = Date()
        let results = await withTaskGroup(of: FileExtractionResult.self, returning: [FileExtractionResult].self) { group in
            for _ in 0..<24 {
                group.addTask {
                    await extractionService.extract(fileURL: fileURL, policy: policy)
                }
            }
            var collected: [FileExtractionResult] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(results.count, 24)
        XCTAssertTrue(results.allSatisfy { $0.telemetry.outcome == .partial && $0.telemetry.detail == "timeout" })
        XCTAssertTrue(results.allSatisfy { $0.content?.warnings.contains("extraction_timeout_metadata_only") == true })
        XCTAssertLessThan(elapsed, 1.2)
    }

    func testWarningOnlyNoTextExtractionIsClassifiedUnsupported() async throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let fileURL = scratch.appendingPathComponent("warning-only.png")
        try Data("placeholder".utf8).write(to: fileURL)

        let extractionService = ContentExtractionService(
            extractors: [WarningOnlyTestExtractor(name: "image_ocr", warning: "image_ocr_empty")],
            scheduleExtraction: { work in
                work()
            },
            scheduleTimeout: { timeoutSeconds, timeout in
                Thread.detachNewThread {
                    Thread.sleep(forTimeInterval: timeoutSeconds)
                    timeout()
                }
            }
        )
        let policy = IndexingPolicy(
            allowlistRoots: [scratch.path],
            excludes: [],
            allowedFileExtensions: ["png"],
            skipUnknownMime: false,
            maxExtractionSecondsPerFile: 0.3
        )

        let result = await extractionService.extract(fileURL: fileURL, policy: policy)
        XCTAssertEqual(result.telemetry.outcome, .unsupported)
        XCTAssertEqual(result.telemetry.detail, "image_ocr_empty")
        XCTAssertNil(result.content)
    }

    func testRetrievalServiceIndexesExtractedFormats() async throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let corpusRoot = scratch.appendingPathComponent("corpus", isDirectory: true)
        try FileManager.default.createDirectory(at: corpusRoot, withIntermediateDirectories: true)
        let fixtures = try createFixtures(at: corpusRoot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixtures.docx.path))

        let paths = makePaths(root: scratch)
        for directory in [paths.daemonDirectory, paths.indexDirectory, paths.cacheDirectory, paths.contextPacksDirectory, paths.logsDirectory, paths.socketDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let service = try RetrievalService(
            configuration: RetrievalDaemonConfiguration(
                authToken: "test-token",
                indexingProfile: "developer",
                startupAllowlistRoots: [corpusRoot.path]
            ),
            paths: paths
        )

        await service.start()
        defer { Task { await service.stop() } }

        _ = try await service.triggerBackfill(limit: 500)
        try await waitForIndexedDocumentCount(service: service, minimum: 6)
        let stats = try await service.indexStats()
        XCTAssertGreaterThanOrEqual(stats.totalDocumentCount, 6)

        let docxSuggest = try await service.suggest(
            request: RetrievalSuggestRequest(
                query: "DOCX plan token",
                sourceFilters: [.file],
                limit: 8,
                typingMode: false,
                includeColdPartitionFallback: true
            )
        )
        XCTAssertTrue(docxSuggest.suggestions.contains(where: { $0.title.contains("plan.docx") }))

        let pptxSuggest = try await service.suggest(
            request: RetrievalSuggestRequest(
                query: "PPTX launch token",
                sourceFilters: [.file],
                limit: 8,
                typingMode: false,
                includeColdPartitionFallback: true
            )
        )
        XCTAssertTrue(pptxSuggest.suggestions.contains(where: { $0.title.contains("slides.pptx") }))

        let xlsxSuggest = try await service.suggest(
            request: RetrievalSuggestRequest(
                query: "XLSX revenue token",
                sourceFilters: [.file],
                limit: 8,
                typingMode: false,
                includeColdPartitionFallback: true
            )
        )
        XCTAssertTrue(xlsxSuggest.suggestions.contains(where: { $0.title.contains("budget.xlsx") }))

        let jsonSuggest = try await service.suggest(
            request: RetrievalSuggestRequest(
                query: "JSON hidden token",
                sourceFilters: [.file],
                limit: 8,
                typingMode: false,
                includeColdPartitionFallback: true
            )
        )
        XCTAssertFalse(jsonSuggest.suggestions.contains(where: { $0.title.contains("output-file-map.json") }))
    }

    func testRetrievalStateSnapshotIncludesRuntimeAndNormalizesIdleProgress() async throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let corpusRoot = scratch.appendingPathComponent("corpus", isDirectory: true)
        try FileManager.default.createDirectory(at: corpusRoot, withIntermediateDirectories: true)
        _ = try createFixtures(at: corpusRoot)

        let paths = makePaths(root: scratch)
        for directory in [paths.daemonDirectory, paths.indexDirectory, paths.cacheDirectory, paths.contextPacksDirectory, paths.logsDirectory, paths.socketDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let service = try RetrievalService(
            configuration: RetrievalDaemonConfiguration(
                authToken: "test-token",
                indexingProfile: "developer",
                startupAllowlistRoots: [corpusRoot.path]
            ),
            paths: paths
        )

        await service.start()
        defer { Task { await service.stop() } }

        _ = try await service.triggerBackfill(limit: 500)
        try await waitForIndexedDocumentCount(service: service, minimum: 6)
        let idleSnapshot = try await waitForIdleState(service: service)

        XCTAssertEqual(idleSnapshot.queueActivity.queueDepth, 0)
        XCTAssertEqual(idleSnapshot.health.inFlightCount, 0)
        XCTAssertEqual(idleSnapshot.currentOperation, .idle)

        let fileRuntime = try XCTUnwrap(idleSnapshot.sourceRuntime.first(where: { $0.sourceType == .file }))
        XCTAssertEqual(fileRuntime.queueDepth, 0)
        XCTAssertEqual(fileRuntime.inFlightCount, 0)
        XCTAssertGreaterThanOrEqual(fileRuntime.cumulativeProcessedCount, 5)
        XCTAssertGreaterThan(fileRuntime.lastScanCandidatesSeen, 0)
        XCTAssertGreaterThanOrEqual(fileRuntime.lastScanCandidatesSeen, fileRuntime.lastScanEventsEmitted)

        let fileProgressRows = idleSnapshot.progress.filter { $0.sourceType == .file }
        XCTAssertFalse(fileProgressRows.isEmpty)
        for row in fileProgressRows where row.status == "idle" {
            XCTAssertEqual(row.percentComplete, 1.0, accuracy: 0.001)
        }
    }

    func testRetrievalServiceSkipsUnchangedDocumentsOnRebackfill() async throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let corpusRoot = scratch.appendingPathComponent("corpus", isDirectory: true)
        try FileManager.default.createDirectory(at: corpusRoot, withIntermediateDirectories: true)
        _ = try createFixtures(at: corpusRoot)

        let paths = makePaths(root: scratch)
        for directory in [paths.daemonDirectory, paths.indexDirectory, paths.cacheDirectory, paths.contextPacksDirectory, paths.logsDirectory, paths.socketDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let service = try RetrievalService(
            configuration: RetrievalDaemonConfiguration(
                authToken: "test-token",
                indexingProfile: "developer",
                startupAllowlistRoots: [corpusRoot.path]
            ),
            paths: paths
        )

        await service.start()
        defer { Task { await service.stop() } }

        _ = try await service.triggerBackfill(limit: 500)
        let firstIdle = try await waitForIdleState(service: service)
        let firstFileRuntime = try XCTUnwrap(firstIdle.sourceRuntime.first(where: { $0.sourceType == .file }))

        _ = try await service.triggerBackfill(limit: 500)
        let secondIdle = try await waitForIdleState(service: service)
        let secondFileRuntime = try XCTUnwrap(secondIdle.sourceRuntime.first(where: { $0.sourceType == .file }))

        XCTAssertEqual(secondFileRuntime.cumulativeProcessedCount, firstFileRuntime.cumulativeProcessedCount)
        XCTAssertEqual(secondFileRuntime.extractionSuccessCount, firstFileRuntime.extractionSuccessCount)
    }

    func testRetrievalServiceSkipsUnchangedUnsupportedDocumentsOnRebackfill() async throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let corpusRoot = scratch.appendingPathComponent("corpus", isDirectory: true)
        try FileManager.default.createDirectory(at: corpusRoot, withIntermediateDirectories: true)
        let unsupportedURL = corpusRoot.appendingPathComponent("broken.png")
        try Data("not-a-real-png".utf8).write(to: unsupportedURL)

        let paths = makePaths(root: scratch)
        for directory in [paths.daemonDirectory, paths.indexDirectory, paths.cacheDirectory, paths.contextPacksDirectory, paths.logsDirectory, paths.socketDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let service = try RetrievalService(
            configuration: RetrievalDaemonConfiguration(
                authToken: "test-token",
                indexingProfile: "developer",
                startupAllowlistRoots: [corpusRoot.path]
            ),
            paths: paths
        )

        await service.start()
        defer { Task { await service.stop() } }

        _ = try await service.triggerBackfill(limit: 500)
        let firstIdle = try await waitForIdleState(service: service)
        let firstFileRuntime = try XCTUnwrap(firstIdle.sourceRuntime.first(where: { $0.sourceType == .file }))
        XCTAssertGreaterThanOrEqual(firstFileRuntime.extractionUnsupportedCount, 1)

        _ = try await service.triggerBackfill(limit: 500)
        let secondIdle = try await waitForIdleState(service: service)
        let secondFileRuntime = try XCTUnwrap(secondIdle.sourceRuntime.first(where: { $0.sourceType == .file }))
        XCTAssertEqual(secondFileRuntime.extractionUnsupportedCount, firstFileRuntime.extractionUnsupportedCount)
    }

    func testRetrievalServiceSkipsUnsupportedFileFormatsWithoutExtraction() async throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let corpusRoot = scratch.appendingPathComponent("corpus", isDirectory: true)
        try FileManager.default.createDirectory(at: corpusRoot, withIntermediateDirectories: true)
        let unsupportedURL = corpusRoot.appendingPathComponent("artifact.dat.nosyncABC")
        try Data("unsupported format content".utf8).write(to: unsupportedURL)

        let paths = makePaths(root: scratch)
        for directory in [paths.daemonDirectory, paths.indexDirectory, paths.cacheDirectory, paths.contextPacksDirectory, paths.logsDirectory, paths.socketDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let service = try RetrievalService(
            configuration: RetrievalDaemonConfiguration(
                authToken: "test-token",
                indexingProfile: "developer",
                startupAllowlistRoots: [corpusRoot.path]
            ),
            paths: paths
        )

        await service.start()
        defer { Task { await service.stop() } }

        _ = try await service.triggerBackfill(limit: 500)
        let idle = try await waitForIdleState(service: service)
        let fileRuntime = try XCTUnwrap(idle.sourceRuntime.first(where: { $0.sourceType == .file }))
        XCTAssertEqual(fileRuntime.extractionUnsupportedCount, 0)
        let unsupportedRunDocCount = try await service.indexStats().totalDocumentCount
        XCTAssertEqual(unsupportedRunDocCount, 0)
    }

    func testRetrievalServiceSkipsConfigurationBuildDirectories() async throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let corpusRoot = scratch.appendingPathComponent("corpus", isDirectory: true)
        try FileManager.default.createDirectory(at: corpusRoot, withIntermediateDirectories: true)
        let normalFile = corpusRoot.appendingPathComponent("note.txt")
        try "normal index token".write(to: normalFile, atomically: true, encoding: .utf8)

        let buildDir = corpusRoot
            .appendingPathComponent("arm64-apple-macosx", isDirectory: true)
            .appendingPathComponent("debug", isDirectory: true)
            .appendingPathComponent("Configuration.build", isDirectory: true)
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
        let buildArtifact = buildDir.appendingPathComponent("artifact.txt")
        try "build artifact token".write(to: buildArtifact, atomically: true, encoding: .utf8)

        let paths = makePaths(root: scratch)
        for directory in [paths.daemonDirectory, paths.indexDirectory, paths.cacheDirectory, paths.contextPacksDirectory, paths.logsDirectory, paths.socketDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let service = try RetrievalService(
            configuration: RetrievalDaemonConfiguration(
                authToken: "test-token",
                indexingProfile: "developer",
                startupAllowlistRoots: [corpusRoot.path]
            ),
            paths: paths
        )

        await service.start()
        defer { Task { await service.stop() } }

        _ = try await service.triggerBackfill(limit: 500)
        try await waitForIndexedDocumentCount(service: service, minimum: 1)
        let idle = try await waitForIdleState(service: service)
        let fileRuntime = try XCTUnwrap(idle.sourceRuntime.first(where: { $0.sourceType == .file }))
        XCTAssertEqual(fileRuntime.extractionUnsupportedCount, 0)
        let buildFilteredDocCount = try await service.indexStats().totalDocumentCount
        XCTAssertEqual(buildFilteredDocCount, 1)

        let normalSuggest = try await service.suggest(
            request: RetrievalSuggestRequest(
                query: "normal index token",
                sourceFilters: [.file],
                limit: 8,
                typingMode: false,
                includeColdPartitionFallback: true
            )
        )
        XCTAssertTrue(normalSuggest.suggestions.contains(where: { $0.title.contains("note.txt") }))

        let buildSuggest = try await service.suggest(
            request: RetrievalSuggestRequest(
                query: "build artifact token",
                sourceFilters: [.file],
                limit: 8,
                typingMode: false,
                includeColdPartitionFallback: true
            )
        )
        XCTAssertFalse(buildSuggest.suggestions.contains(where: { $0.title.contains("artifact.txt") }))
    }

    func testRetrievalServiceSkipsCodeFilesCompletely() async throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let corpusRoot = scratch.appendingPathComponent("corpus", isDirectory: true)
        try FileManager.default.createDirectory(at: corpusRoot, withIntermediateDirectories: true)
        let codeFile = corpusRoot.appendingPathComponent("source.swift")
        let textFile = corpusRoot.appendingPathComponent("note.txt")
        try "code only token retrieval mismatch".write(to: codeFile, atomically: true, encoding: .utf8)
        try "plain text retrieval token".write(to: textFile, atomically: true, encoding: .utf8)

        let paths = makePaths(root: scratch)
        for directory in [paths.daemonDirectory, paths.indexDirectory, paths.cacheDirectory, paths.contextPacksDirectory, paths.logsDirectory, paths.socketDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let service = try RetrievalService(
            configuration: RetrievalDaemonConfiguration(
                authToken: "test-token",
                indexingProfile: "developer",
                startupAllowlistRoots: [corpusRoot.path]
            ),
            paths: paths
        )

        await service.start()
        defer { Task { await service.stop() } }

        _ = try await service.triggerBackfill(limit: 500)
        try await waitForIndexedDocumentCount(service: service, minimum: 1)
        let idle = try await waitForIdleState(service: service)

        let stats = try await service.indexStats()
        XCTAssertEqual(stats.totalDocumentCount, 1)
        let fileRuntime = try XCTUnwrap(idle.sourceRuntime.first(where: { $0.sourceType == .file }))
        XCTAssertEqual(fileRuntime.extractionUnsupportedCount, 0)

        let codeSuggest = try await service.suggest(
            request: RetrievalSuggestRequest(
                query: "code only token retrieval mismatch",
                sourceFilters: [.file],
                limit: 8,
                typingMode: false,
                includeColdPartitionFallback: true
            )
        )
        XCTAssertFalse(codeSuggest.suggestions.contains(where: { $0.title.contains("source.swift") }))

        let textSuggest = try await service.suggest(
            request: RetrievalSuggestRequest(
                query: "plain text retrieval token",
                sourceFilters: [.file],
                limit: 8,
                typingMode: false,
                includeColdPartitionFallback: true
            )
        )
        XCTAssertTrue(textSuggest.suggestions.contains(where: { $0.title.contains("note.txt") }))
    }

    func testRetrievalServiceResumesAfterSleepAndIndexesFilesCreatedDuringPause() async throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let corpusRoot = scratch.appendingPathComponent("corpus", isDirectory: true)
        try FileManager.default.createDirectory(at: corpusRoot, withIntermediateDirectories: true)
        _ = try createFixtures(at: corpusRoot)

        let paths = makePaths(root: scratch)
        for directory in [paths.daemonDirectory, paths.indexDirectory, paths.cacheDirectory, paths.contextPacksDirectory, paths.logsDirectory, paths.socketDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let service = try RetrievalService(
            configuration: RetrievalDaemonConfiguration(
                authToken: "test-token",
                indexingProfile: "developer",
                startupAllowlistRoots: [corpusRoot.path]
            ),
            paths: paths
        )

        await service.start()
        defer { Task { await service.stop() } }

        _ = try await service.triggerBackfill(limit: 500)
        _ = try await waitForIdleState(service: service)
        let baselineCount = try await service.indexStats().totalDocumentCount

        await service.pauseForSystemSleep()
        let wakeFileURL = corpusRoot.appendingPathComponent("wake-resume.txt")
        try "wake resume token".write(to: wakeFileURL, atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(300))
        let pausedCount = try await service.indexStats().totalDocumentCount
        XCTAssertEqual(pausedCount, baselineCount)

        await service.resumeAfterSystemWake()
        try await waitForIndexedDocumentCount(service: service, minimum: baselineCount + 1)

        let suggest = try await service.suggest(
            request: RetrievalSuggestRequest(
                query: "wake resume token",
                sourceFilters: [.file],
                limit: 8,
                typingMode: false,
                includeColdPartitionFallback: true
            )
        )
        XCTAssertTrue(suggest.suggestions.contains(where: { $0.title.contains("wake-resume.txt") }))
    }

    func testRetrievalStoreDeletesDocumentsWhenPathRemoved() async throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let paths = makePaths(root: scratch)
        for directory in [paths.daemonDirectory, paths.indexDirectory, paths.cacheDirectory, paths.contextPacksDirectory, paths.logsDirectory, paths.socketDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let store = RetrievalStore(dbPath: paths.metadataDBPath, contextPackDirectory: paths.contextPacksDirectory)
        try await store.openAndMigrate()

        let removedRoot = scratch.appendingPathComponent("to-remove", isDirectory: true)
        let keepRoot = scratch.appendingPathComponent("keep", isDirectory: true)
        try FileManager.default.createDirectory(at: removedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: keepRoot, withIntermediateDirectories: true)

        let removedPath = removedRoot.appendingPathComponent("a.txt").path
        let keptPath = keepRoot.appendingPathComponent("b.txt").path
        let removedDoc = RetrievalDocument(
            id: "doc-remove",
            sourceType: .file,
            sourceId: removedPath,
            title: "remove",
            body: "remove token",
            sourcePathOrHandle: removedPath,
            updatedAt: Date(),
            risk: .low,
            partition: "hot",
            searchable: true
        )
        let keptDoc = RetrievalDocument(
            id: "doc-keep",
            sourceType: .file,
            sourceId: keptPath,
            title: "keep",
            body: "keep token",
            sourcePathOrHandle: keptPath,
            updatedAt: Date(),
            risk: .low,
            partition: "hot",
            searchable: true
        )
        let removeChunk = RetrievalChunk(id: "doc-remove:0", documentId: "doc-remove", text: "remove token", index: 0, embedding: [0.1, 0.2])
        let keepChunk = RetrievalChunk(id: "doc-keep:0", documentId: "doc-keep", text: "keep token", index: 0, embedding: [0.3, 0.4])
        try await store.upsertDocument(removedDoc, chunks: [removeChunk])
        try await store.upsertDocument(keptDoc, chunks: [keepChunk])
        try await store.insertGraphEdges([
            GraphEdge(
                id: "doc-remove:mentions:remove",
                sourceNode: "doc-remove",
                targetNode: "remove",
                edgeType: "mentions",
                confidence: 0.5,
                weight: 1.0,
                sourceType: .file,
                eventTime: Date(),
                updatedAt: Date()
            ),
        ])

        let deletedCount = try await store.deleteDocumentsForPath(sourceType: .file, sourcePathOrHandle: removedRoot.path)
        XCTAssertEqual(deletedCount, 1)
        let removedFetched = try await store.fetchDocument(for: "doc-remove")
        let keptFetched = try await store.fetchDocument(for: "doc-keep")
        XCTAssertNil(removedFetched)
        XCTAssertNotNil(keptFetched)

        let removeLexical = try await store.lexicalSearch(
            queryText: "remove",
            sourceFilters: [.file],
            partitionFilter: [],
            limit: 8
        )
        XCTAssertFalse(removeLexical.contains(where: { $0.documentId == "doc-remove" }))
        let keepLexical = try await store.lexicalSearch(
            queryText: "keep",
            sourceFilters: [.file],
            partitionFilter: [],
            limit: 8
        )
        XCTAssertTrue(keepLexical.contains(where: { $0.documentId == "doc-keep" }))
    }

    func testRetrievalStoreTreatsFailedOrUnsupportedAttemptAsCurrent() async throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let paths = makePaths(root: scratch)
        for directory in [paths.daemonDirectory, paths.indexDirectory, paths.cacheDirectory, paths.contextPacksDirectory, paths.logsDirectory, paths.socketDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let store = RetrievalStore(dbPath: paths.metadataDBPath, contextPackDirectory: paths.contextPacksDirectory)
        try await store.openAndMigrate()

        let sourceID = "/tmp/failure-case.png"
        let now = Date()
        try await store.recordIngestionAttempt(
            sourceType: .file,
            sourceId: sourceID,
            sourcePathOrHandle: sourceID,
            updatedAt: now,
            outcome: .unsupported
        )
        let unsupportedCurrent = try await store.isIngestionAttemptCurrent(
            sourceType: .file,
            sourceId: sourceID,
            updatedAt: now
        )
        let unsupportedAfterFutureEdit = try await store.isIngestionAttemptCurrent(
            sourceType: .file,
            sourceId: sourceID,
            updatedAt: now.addingTimeInterval(60)
        )
        XCTAssertTrue(unsupportedCurrent)
        XCTAssertFalse(unsupportedAfterFutureEdit)

        try await store.recordIngestionAttempt(
            sourceType: .file,
            sourceId: sourceID,
            sourcePathOrHandle: sourceID,
            updatedAt: now,
            outcome: .failed
        )
        let failedCurrent = try await store.isIngestionAttemptCurrent(
            sourceType: .file,
            sourceId: sourceID,
            updatedAt: now
        )
        XCTAssertTrue(failedCurrent)

        try await store.recordIngestionAttempt(
            sourceType: .file,
            sourceId: sourceID,
            sourcePathOrHandle: sourceID,
            updatedAt: now,
            outcome: .partial
        )
        let partialCurrent = try await store.isIngestionAttemptCurrent(
            sourceType: .file,
            sourceId: sourceID,
            updatedAt: now
        )
        XCTAssertFalse(partialCurrent)
    }

    func testQueueSnapshotStorageIsBoundedAndReclaimable() async throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let paths = makePaths(root: scratch)
        for directory in [paths.daemonDirectory, paths.indexDirectory, paths.cacheDirectory, paths.contextPacksDirectory, paths.logsDirectory, paths.socketDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let store = RetrievalStore(dbPath: paths.metadataDBPath, contextPackDirectory: paths.contextPacksDirectory)
        try await store.openAndMigrate()

        func makeEvents(start: Int, count: Int) -> [IngestionEvent] {
            (start..<(start + count)).map { idx in
                IngestionEvent(
                    sourceType: .file,
                    scopeLabel: "default",
                    sourceId: "event-\(idx)",
                    title: "Event \(idx)",
                    body: String(repeating: "x", count: 256),
                    sourcePathOrHandle: "/tmp/file-\(idx).txt",
                    occurredAt: Date(timeIntervalSince1970: TimeInterval(idx))
                )
            }
        }

        try await store.saveQueueSnapshot(items: makeEvents(start: 0, count: 240))
        try await store.saveQueueSnapshot(items: makeEvents(start: 10_000, count: 240))

        let latest = try await store.loadLatestQueueSnapshot()
        XCTAssertEqual(latest.count, 128)
        XCTAssertEqual(latest.first?.sourceId, "event-10112")
        XCTAssertEqual(latest.last?.sourceId, "event-10239")

        let reclaimed = try await store.reclaimQueueSnapshotStorageIfNeeded()
        XCTAssertTrue(reclaimed)
        let afterReclaim = try await store.loadLatestQueueSnapshot()
        XCTAssertTrue(afterReclaim.isEmpty)
    }

    func testHybridSearchRejectsWeakVectorOnlyCandidate() async throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let paths = makePaths(root: scratch)
        for directory in [paths.daemonDirectory, paths.indexDirectory, paths.cacheDirectory, paths.contextPacksDirectory, paths.logsDirectory, paths.socketDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let store = RetrievalStore(dbPath: paths.metadataDBPath, contextPackDirectory: paths.contextPacksDirectory)
        try await store.openAndMigrate()

        let query = "phase one precision sentinel query"
        let runtime = EmbeddingRuntime()
        let (queryEmbeddings, _) = try await runtime.embed(texts: [query])
        let queryVector = try XCTUnwrap(queryEmbeddings.first)
        let weakVector = makeVector(withCosine: 0.02, relativeTo: queryVector)

        let weakDocument = RetrievalDocument(
            id: "doc-weak-vector",
            sourceType: .file,
            sourceId: "/tmp/unrelated-vector.txt",
            title: "unrelated-vector.txt",
            body: "general archive planning notes",
            sourcePathOrHandle: "/tmp/unrelated-vector.txt",
            updatedAt: Date(),
            risk: .low,
            partition: "hot",
            searchable: true
        )
        let weakChunk = RetrievalChunk(
            id: "doc-weak-vector:0",
            documentId: "doc-weak-vector",
            text: "general archive planning notes",
            index: 0,
            embedding: weakVector
        )
        try await store.upsertDocument(weakDocument, chunks: [weakChunk])

        let engine = HybridSearchEngine(
            store: store,
            embeddingRuntime: runtime,
            graphAugmentor: GraphAugmentor(store: store),
            reranker: LocalReranker()
        )
        let response = try await engine.suggest(
            request: RetrievalSuggestRequest(
                query: query,
                sourceFilters: [.file],
                limit: 8,
                typingMode: false,
                includeColdPartitionFallback: true
            )
        )

        XCTAssertTrue(response.suggestions.isEmpty)
    }

    func testGraphBoostDoesNotOvertakeStrongDirectMatch() async throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let paths = makePaths(root: scratch)
        for directory in [paths.daemonDirectory, paths.indexDirectory, paths.cacheDirectory, paths.contextPacksDirectory, paths.logsDirectory, paths.socketDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let store = RetrievalStore(dbPath: paths.metadataDBPath, contextPackDirectory: paths.contextPacksDirectory)
        try await store.openAndMigrate()

        let query = "launch roadmap alpha planning"
        let runtime = EmbeddingRuntime()
        let (queryEmbeddings, _) = try await runtime.embed(texts: [query])
        let queryVector = try XCTUnwrap(queryEmbeddings.first)
        let strongVector = makeVector(withCosine: 0.42, relativeTo: queryVector)
        let weakVector = makeVector(withCosine: 0.36, relativeTo: queryVector)

        let strongDocument = RetrievalDocument(
            id: "doc-strong-direct",
            sourceType: .file,
            sourceId: "/tmp/launch-roadmap.txt",
            title: "launch-roadmap.txt",
            body: "launch roadmap alpha planning with milestones",
            sourcePathOrHandle: "/tmp/launch-roadmap.txt",
            updatedAt: Date(),
            risk: .low,
            partition: "hot",
            searchable: true
        )
        let weakDocument = RetrievalDocument(
            id: "doc-weak-graph",
            sourceType: .file,
            sourceId: "/tmp/background-notes.txt",
            title: "background-notes.txt",
            body: "historical notes and archive references",
            sourcePathOrHandle: "/tmp/background-notes.txt",
            updatedAt: Date(),
            risk: .low,
            partition: "hot",
            searchable: true
        )
        try await store.upsertDocument(
            strongDocument,
            chunks: [
                RetrievalChunk(
                    id: "doc-strong-direct:0",
                    documentId: "doc-strong-direct",
                    text: "launch roadmap alpha planning with milestones",
                    index: 0,
                    embedding: strongVector
                ),
            ]
        )
        try await store.upsertDocument(
            weakDocument,
            chunks: [
                RetrievalChunk(
                    id: "doc-weak-graph:0",
                    documentId: "doc-weak-graph",
                    text: "historical notes and archive references",
                    index: 0,
                    embedding: weakVector
                ),
            ]
        )
        let graphEdges: [GraphEdge] = (0..<48).map { index in
            GraphEdge(
                id: "doc-weak-graph:boost:\(index)",
                sourceNode: "doc-weak-graph",
                targetNode: "shared-node-\(index)",
                edgeType: "mentions",
                confidence: 1.0,
                weight: 2.0,
                sourceType: .file,
                eventTime: Date(),
                updatedAt: Date()
            )
        }
        try await store.insertGraphEdges(graphEdges)

        let engine = HybridSearchEngine(
            store: store,
            embeddingRuntime: runtime,
            graphAugmentor: GraphAugmentor(store: store),
            reranker: LocalReranker()
        )
        let response = try await engine.suggest(
            request: RetrievalSuggestRequest(
                query: query,
                sourceFilters: [.file],
                limit: 8,
                typingMode: false,
                includeColdPartitionFallback: true
            )
        )
        XCTAssertTrue(response.suggestions.contains(where: { $0.id == "doc-weak-graph" }))
        XCTAssertEqual(response.suggestions.first?.id, "doc-strong-direct")
    }

    func testSimilarityFirstVectorSelectionBeatsRecencyBias() async throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let paths = makePaths(root: scratch)
        for directory in [paths.daemonDirectory, paths.indexDirectory, paths.cacheDirectory, paths.contextPacksDirectory, paths.logsDirectory, paths.socketDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let store = RetrievalStore(dbPath: paths.metadataDBPath, contextPackDirectory: paths.contextPacksDirectory)
        try await store.openAndMigrate()

        let query = "phase two ordering sentinel"
        let runtime = EmbeddingRuntime()
        let (queryEmbeddings, _) = try await runtime.embed(texts: [query])
        let queryVector = try XCTUnwrap(queryEmbeddings.first)

        let oldRelevantVector = makeVector(withCosine: 0.72, relativeTo: queryVector)
        let distractorVector = makeVector(withCosine: 0.19, relativeTo: queryVector)
        let oldRelevantDocID = "doc-old-relevant"
        let oldRelevantDate = Date().addingTimeInterval(-86_400 * 120)

        let oldRelevantDocument = RetrievalDocument(
            id: oldRelevantDocID,
            sourceType: .file,
            sourceId: "/tmp/old-relevant.txt",
            title: "old-relevant.txt",
            body: "historical strategy draft",
            sourcePathOrHandle: "/tmp/old-relevant.txt",
            updatedAt: oldRelevantDate,
            risk: .low,
            partition: "hot",
            searchable: true
        )
        try await store.upsertDocument(
            oldRelevantDocument,
            chunks: [
                RetrievalChunk(
                    id: "\(oldRelevantDocID):0",
                    documentId: oldRelevantDocID,
                    text: "historical strategy draft",
                    index: 0,
                    embedding: oldRelevantVector
                ),
            ]
        )

        for index in 0..<260 {
            let docID = "doc-recent-distractor-\(index)"
            let sourcePath = "/tmp/recent-distractor-\(index).txt"
            let document = RetrievalDocument(
                id: docID,
                sourceType: .file,
                sourceId: sourcePath,
                title: "recent-distractor-\(index).txt",
                body: "routine status log entry",
                sourcePathOrHandle: sourcePath,
                updatedAt: Date().addingTimeInterval(TimeInterval(index)),
                risk: .low,
                partition: "hot",
                searchable: true
            )
            try await store.upsertDocument(
                document,
                chunks: [
                    RetrievalChunk(
                        id: "\(docID):0",
                        documentId: docID,
                        text: "routine status log entry",
                        index: 0,
                        embedding: distractorVector
                    ),
                ]
            )
        }

        let engine = HybridSearchEngine(
            store: store,
            embeddingRuntime: runtime,
            graphAugmentor: GraphAugmentor(store: store),
            reranker: LocalReranker()
        )
        let response = try await engine.suggest(
            request: RetrievalSuggestRequest(
                query: query,
                sourceFilters: [.file],
                limit: 8,
                typingMode: true,
                includeColdPartitionFallback: false
            )
        )

        XCTAssertEqual(response.suggestions.first?.id, oldRelevantDocID)
    }

    func testVectorOnlySuggestionUsesChunkTextSnippet() async throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let paths = makePaths(root: scratch)
        for directory in [paths.daemonDirectory, paths.indexDirectory, paths.cacheDirectory, paths.contextPacksDirectory, paths.logsDirectory, paths.socketDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let store = RetrievalStore(dbPath: paths.metadataDBPath, contextPackDirectory: paths.contextPacksDirectory)
        try await store.openAndMigrate()

        let query = "phase two snippet sentinel query"
        let runtime = EmbeddingRuntime()
        let (queryEmbeddings, _) = try await runtime.embed(texts: [query])
        let queryVector = try XCTUnwrap(queryEmbeddings.first)
        let vector = makeVector(withCosine: 0.58, relativeTo: queryVector)

        let docID = "doc-snippet-evidence"
        let chunkText = "Vector snippet sentinel phrase for ranking evidence."
        let title = "plain-title-without-sentinel.txt"
        let document = RetrievalDocument(
            id: docID,
            sourceType: .file,
            sourceId: "/tmp/\(title)",
            title: title,
            body: "archive body without direct lexical overlap",
            sourcePathOrHandle: "/tmp/\(title)",
            updatedAt: Date(),
            risk: .low,
            partition: "hot",
            searchable: true
        )
        try await store.upsertDocument(
            document,
            chunks: [
                RetrievalChunk(
                    id: "\(docID):0",
                    documentId: docID,
                    text: chunkText,
                    index: 0,
                    embedding: vector
                ),
            ]
        )

        let engine = HybridSearchEngine(
            store: store,
            embeddingRuntime: runtime,
            graphAugmentor: GraphAugmentor(store: store),
            reranker: LocalReranker()
        )
        let response = try await engine.suggest(
            request: RetrievalSuggestRequest(
                query: query,
                sourceFilters: [.file],
                limit: 8,
                typingMode: false,
                includeColdPartitionFallback: true
            )
        )

        let first = try XCTUnwrap(response.suggestions.first)
        XCTAssertEqual(first.id, docID)
        XCTAssertTrue(first.snippet.localizedCaseInsensitiveContains("snippet sentinel phrase"))
        XCTAssertNotEqual(first.snippet, title)
    }

    func testDirectorySuggestionSurfacesTemplateFolder() async throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let paths = makePaths(root: scratch)
        for directory in [paths.daemonDirectory, paths.indexDirectory, paths.cacheDirectory, paths.contextPacksDirectory, paths.logsDirectory, paths.socketDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let store = RetrievalStore(dbPath: paths.metadataDBPath, contextPackDirectory: paths.contextPacksDirectory)
        try await store.openAndMigrate()

        let query = "Create a detailed PowerPoint presentation for this research paper using the NYU Powerpoint template."
        let runtime = EmbeddingRuntime()
        let (queryEmbeddings, _) = try await runtime.embed(texts: [query])
        let queryVector = try XCTUnwrap(queryEmbeddings.first)

        let templateDirectory = "/tmp/NYU Template"
        let primaryVector = makeVector(withCosine: 0.74, relativeTo: queryVector)
        let secondaryVector = makeVector(withCosine: 0.68, relativeTo: queryVector)

        try await store.upsertDocument(
            RetrievalDocument(
                id: "doc-nyu-template-guide",
                sourceType: .file,
                sourceId: "\(templateDirectory)/template-guide.md",
                title: "template-guide.md",
                body: "NYU PowerPoint template guide and slide master instructions.",
                sourcePathOrHandle: "\(templateDirectory)/template-guide.md",
                updatedAt: Date(),
                risk: .low,
                partition: "hot",
                searchable: true
            ),
            chunks: [
                RetrievalChunk(
                    id: "doc-nyu-template-guide:0",
                    documentId: "doc-nyu-template-guide",
                    text: "NYU PowerPoint template guide and slide master instructions.",
                    index: 0,
                    embedding: primaryVector
                ),
            ]
        )
        try await store.upsertDocument(
            RetrievalDocument(
                id: "doc-nyu-template-theme",
                sourceType: .file,
                sourceId: "\(templateDirectory)/theme/colors.md",
                title: "colors.md",
                body: "Template color palette and presentation typography references.",
                sourcePathOrHandle: "\(templateDirectory)/theme/colors.md",
                updatedAt: Date(),
                risk: .low,
                partition: "hot",
                searchable: true
            ),
            chunks: [
                RetrievalChunk(
                    id: "doc-nyu-template-theme:0",
                    documentId: "doc-nyu-template-theme",
                    text: "Template color palette and presentation typography references.",
                    index: 0,
                    embedding: secondaryVector
                ),
            ]
        )

        let engine = HybridSearchEngine(
            store: store,
            embeddingRuntime: runtime,
            graphAugmentor: GraphAugmentor(store: store),
            reranker: LocalReranker()
        )
        let response = try await engine.suggest(
            request: RetrievalSuggestRequest(
                query: query,
                sourceFilters: [.file],
                limit: 12,
                typingMode: false,
                includeColdPartitionFallback: true
            )
        )

        let directorySuggestion = try XCTUnwrap(
            response.suggestions.first { $0.sourcePathOrHandle == templateDirectory }
        )
        XCTAssertTrue(directorySuggestion.reasons.contains("directory"))
        XCTAssertTrue(directorySuggestion.title.localizedCaseInsensitiveContains("nyu template"))
        let rank = try XCTUnwrap(response.suggestions.firstIndex(where: { $0.sourcePathOrHandle == templateDirectory }))
        XCTAssertLessThanOrEqual(rank, 3)
    }

    private func makeVector(withCosine targetCosine: Float, relativeTo reference: [Float]) -> [Float] {
        let normalizedReference = normalized(reference)
        guard !normalizedReference.isEmpty else { return [] }

        let firstValue = normalizedReference.first ?? Float(0)
        var orthogonal: [Float] = Array(normalizedReference.dropFirst()) + [firstValue]
        var projection: Float = 0
        for index in normalizedReference.indices {
            projection += orthogonal[index] * normalizedReference[index]
        }
        for index in orthogonal.indices {
            orthogonal[index] -= projection * normalizedReference[index]
        }
        orthogonal = normalized(orthogonal)
        if orthogonal.allSatisfy({ abs($0) < 0.000_001 }) {
            orthogonal = Array(repeating: 0, count: normalizedReference.count)
            orthogonal[0] = 1
            var fallbackProjection: Float = 0
            for index in normalizedReference.indices {
                fallbackProjection += orthogonal[index] * normalizedReference[index]
            }
            for index in orthogonal.indices {
                orthogonal[index] -= fallbackProjection * normalizedReference[index]
            }
            orthogonal = normalized(orthogonal)
        }

        let clipped = max(-0.95, min(0.95, targetCosine))
        let orthogonalScale = sqrt(max(0, 1 - (clipped * clipped)))
        var combined = Array(repeating: Float(0), count: normalizedReference.count)
        for index in combined.indices {
            combined[index] = (clipped * normalizedReference[index]) + (orthogonalScale * orthogonal[index])
        }
        return normalized(combined)
    }

    private func normalized(_ vector: [Float]) -> [Float] {
        guard !vector.isEmpty else { return [] }
        var sumSquares: Float = 0
        for value in vector {
            sumSquares += value * value
        }
        let magnitude = sqrt(sumSquares)
        guard magnitude > 0.000_001 else {
            return vector
        }
        return vector.map { $0 / magnitude }
    }

    private func createFixtures(at root: URL) throws -> (docx: URL, pptx: URL, xlsx: URL, image: URL, pdf: URL, json: URL) {
        let docxURL = root.appendingPathComponent("plan.docx")
        try createZipArchive(
            at: docxURL,
            files: [
                "word/document.xml": """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
                  <w:body>
                    <w:p><w:r><w:t>DOCX plan token</w:t></w:r></w:p>
                  </w:body>
                </w:document>
                """
            ]
        )

        let pptxURL = root.appendingPathComponent("slides.pptx")
        try createZipArchive(
            at: pptxURL,
            files: [
                "ppt/slides/slide1.xml": """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
                  <p:cSld>
                    <p:spTree>
                      <p:sp>
                        <p:txBody>
                          <a:p><a:r><a:t>PPTX launch token</a:t></a:r></a:p>
                        </p:txBody>
                      </p:sp>
                    </p:spTree>
                  </p:cSld>
                </p:sld>
                """
            ]
        )

        let xlsxURL = root.appendingPathComponent("budget.xlsx")
        try createZipArchive(
            at: xlsxURL,
            files: [
                "xl/sharedStrings.xml": """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="1" uniqueCount="1">
                  <si><t>XLSX revenue token</t></si>
                </sst>
                """,
                "xl/worksheets/sheet1.xml": """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
                  <sheetData>
                    <row r="1"><c r="A1" t="s"><v>0</v></c></row>
                  </sheetData>
                </worksheet>
                """
            ]
        )

        let imageURL = root.appendingPathComponent("whiteboard.png")
        try createImage(with: "OCR IMAGE TOKEN", at: imageURL)

        let pdfURL = root.appendingPathComponent("scan.pdf")
        try createImageBackedPDF(with: "OCR PDF TOKEN", at: pdfURL)
        let jsonURL = root.appendingPathComponent("output-file-map.json")
        try """
        {
          "artifact": "map",
          "keyword": "JSON hidden token",
          "entries": ["a", "b", "c"]
        }
        """.write(to: jsonURL, atomically: true, encoding: .utf8)
        return (docxURL, pptxURL, xlsxURL, imageURL, pdfURL, jsonURL)
    }

    private func createZipArchive(at destinationURL: URL, files: [String: String]) throws {
        let archive = try Archive(url: destinationURL, accessMode: .create)
        for (path, raw) in files {
            let data = Data(raw.utf8)
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                compressionMethod: .deflate,
                provider: { position, size in
                    let start = min(Int(position), data.count)
                    let end = min(start + size, data.count)
                    if start >= end {
                        return Data()
                    }
                    return data.subdata(in: start..<end)
                }
            )
        }
    }

    private func createImage(with text: String, at destinationURL: URL) throws {
        let size = NSSize(width: 1_400, height: 700)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 88, weight: .bold),
            .foregroundColor: NSColor.black,
            .paragraphStyle: style,
        ]
        let rect = NSRect(x: 80, y: 250, width: 1_240, height: 220)
        text.draw(in: rect, withAttributes: attrs)
        image.unlockFocus()

        guard let cgImage = image.cgImage else {
            XCTFail("Unable to render image")
            return
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            XCTFail("Unable to encode PNG")
            return
        }
        try pngData.write(to: destinationURL, options: .atomic)
    }

    private func createImageBackedPDF(with text: String, at destinationURL: URL) throws {
        let imageURL = destinationURL.deletingPathExtension().appendingPathExtension("png")
        try createImage(with: text, at: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }

        guard let imageData = try? Data(contentsOf: imageURL), let image = NSImage(data: imageData), let page = PDFPage(image: image) else {
            XCTFail("Unable to build image-backed PDF")
            return
        }
        let doc = PDFDocument()
        doc.insert(page, at: 0)
        XCTAssertTrue(doc.write(to: destinationURL))
    }

    private func createLegacyWordDoc(with text: String, at destinationURL: URL) throws {
        let attributed = NSAttributedString(string: text)
        let data = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.docFormat]
        )
        try data.write(to: destinationURL, options: .atomic)
    }

    private func makeScratchDirectory() throws -> URL {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("hivecrew-retrieval-extract-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }

    private func makePaths(root: URL) -> RetrievalPaths {
        RetrievalPaths(
            daemonDirectory: root.appendingPathComponent("daemon", isDirectory: true),
            indexDirectory: root.appendingPathComponent("index", isDirectory: true),
            cacheDirectory: root.appendingPathComponent("cache", isDirectory: true),
            contextPacksDirectory: root.appendingPathComponent("packs", isDirectory: true),
            logsDirectory: root.appendingPathComponent("logs", isDirectory: true),
            socketDirectory: root.appendingPathComponent("sockets", isDirectory: true),
            launchAgentPlistPath: root.appendingPathComponent("com.hivecrew.retrievald.plist"),
            daemonConfigPath: root.appendingPathComponent("retrieval-daemon.json"),
            daemonBinaryPath: root.appendingPathComponent("hivecrew-retrieval-daemon"),
            metadataDBPath: root.appendingPathComponent("index/metadata.db"),
            vectorShardPath: root.appendingPathComponent("index/vectors.jsonl"),
            ingestionLogPath: root.appendingPathComponent("logs/ingestion.log"),
            metricsPath: root.appendingPathComponent("logs/metrics.json")
        )
    }

    private func waitForIndexedDocumentCount(service: RetrievalService, minimum: Int) async throws {
        for _ in 0..<80 {
            let stats = try await service.indexStats()
            if stats.totalDocumentCount >= minimum {
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTFail("Document count did not reach \(minimum) in time")
    }

    private func waitForIdleState(service: RetrievalService) async throws -> RetrievalStateSnapshot {
        for _ in 0..<100 {
            let state = try await service.stateSnapshot()
            let fileRuntime = state.sourceRuntime.first(where: { $0.sourceType == .file })
            if state.queueActivity.queueDepth == 0,
                state.health.inFlightCount == 0,
                state.currentOperation == .idle,
                fileRuntime?.currentOperation == .idle
            {
                return state
            }
            try await Task.sleep(for: .milliseconds(120))
        }
        return try await service.stateSnapshot()
    }
}

private extension NSImage {
    var cgImage: CGImage? {
        var rect = NSRect(origin: .zero, size: size)
        return self.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}

private actor EventAccumulator {
    private var value: [IngestionEvent] = []

    func append(_ events: [IngestionEvent]) {
        value.append(contentsOf: events)
    }

    func items() -> [IngestionEvent] {
        value
    }
}

private actor ScanStatsAccumulator {
    private var value: [FileConnector.ScanBatchStats] = []

    func append(_ stats: FileConnector.ScanBatchStats) {
        value.append(stats)
    }

    func items() -> [FileConnector.ScanBatchStats] {
        value
    }
}

private struct BlockingTimeoutTestExtractor: FileContentExtractor {
    let name = "blocking_timeout_test"
    let delaySeconds: TimeInterval

    func canHandle(fileURL _: URL, contentType _: UTType?) -> Bool {
        true
    }

    func extract(fileURL _: URL, contentType _: UTType?, policy _: IndexingPolicy) throws -> ExtractedContent? {
        Thread.sleep(forTimeInterval: delaySeconds)
        return nil
    }
}

private struct WarningOnlyTestExtractor: FileContentExtractor {
    let name: String
    let warning: String

    func canHandle(fileURL _: URL, contentType _: UTType?) -> Bool {
        true
    }

    func extract(fileURL _: URL, contentType _: UTType?, policy _: IndexingPolicy) throws -> ExtractedContent? {
        ExtractedContent(
            text: "",
            title: nil,
            metadata: ["synthetic": "true"],
            warnings: [warning],
            wasOCRUsed: name == "image_ocr"
        )
    }
}
