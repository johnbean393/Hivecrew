import Foundation
import XCTest
@testable import HivecrewRetrievalCore
import HivecrewRetrievalProtocol

final class RetrievalBenchmarksTests: XCTestCase {
    func testTypingLatencyBenchmarkSample() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("hivecrew-retrieval-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let corpusRoot = scratch.appendingPathComponent("corpus", isDirectory: true)
        try FileManager.default.createDirectory(at: corpusRoot, withIntermediateDirectories: true)
        try seedCorpus(at: corpusRoot)

        let paths = RetrievalPaths(
            daemonDirectory: scratch.appendingPathComponent("daemon", isDirectory: true),
            indexDirectory: scratch.appendingPathComponent("index", isDirectory: true),
            cacheDirectory: scratch.appendingPathComponent("cache", isDirectory: true),
            contextPacksDirectory: scratch.appendingPathComponent("packs", isDirectory: true),
            logsDirectory: scratch.appendingPathComponent("logs", isDirectory: true),
            socketDirectory: scratch.appendingPathComponent("sockets", isDirectory: true),
            launchAgentPlistPath: scratch.appendingPathComponent("com.hivecrew.retrievald.plist"),
            daemonConfigPath: scratch.appendingPathComponent("retrieval-daemon.json"),
            daemonBinaryPath: scratch.appendingPathComponent("hivecrew-retrieval-daemon"),
            metadataDBPath: scratch.appendingPathComponent("index/metadata.db"),
            vectorShardPath: scratch.appendingPathComponent("index/vectors.jsonl"),
            ingestionLogPath: scratch.appendingPathComponent("logs/ingestion.log"),
            metricsPath: scratch.appendingPathComponent("logs/metrics.json")
        )
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
        _ = try await service.triggerBackfill(limit: 500)
        try? await Task.sleep(for: .milliseconds(500))

        let benchmark = try await service.runBenchmarkSample(
            queries: [
                "redis queue backpressure",
                "project timeline and meeting notes",
                "api auth token"
            ]
        )

        XCTAssertEqual(benchmark.keys.count, 3)
        for latency in benchmark.values {
            XCTAssertLessThan(latency, 2_000)
        }
    }

    private func seedCorpus(at root: URL) throws {
        let files: [(String, String)] = [
            ("engineering/queueing.md", "Backpressure for ingestion queues should prefer interactive retrieval over backlog jobs."),
            ("engineering/retrieval.md", "Hybrid search combines lexical FTS, vector similarity, and recency scoring."),
            ("notes/meeting.txt", "Project timeline: finalize daemon API, integrate prompt drawer, benchmark typing latency."),
            ("security/keys.txt", "Never expose auth tokens in inline snippets. Redact secrets before prompt injection."),
        ]
        for (relative, body) in files {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

