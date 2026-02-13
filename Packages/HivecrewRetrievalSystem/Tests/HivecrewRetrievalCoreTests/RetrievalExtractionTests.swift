import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers
import XCTest
import ZIPFoundation
@testable import HivecrewRetrievalCore
import HivecrewRetrievalProtocol

final class RetrievalExtractionTests: XCTestCase {
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

        XCTAssertEqual(result.telemetry.outcome, .failed)
        XCTAssertEqual(result.telemetry.detail, "timeout")
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
        XCTAssertTrue(results.allSatisfy { $0.telemetry.outcome == .failed && $0.telemetry.detail == "timeout" })
        XCTAssertLessThan(elapsed, 1.2)
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
