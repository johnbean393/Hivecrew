import Foundation
import HivecrewShared

public struct RetrievalPaths: Sendable {
    public let daemonDirectory: URL
    public let indexDirectory: URL
    public let cacheDirectory: URL
    public let contextPacksDirectory: URL
    public let logsDirectory: URL
    public let socketDirectory: URL
    public let launchAgentPlistPath: URL
    public let daemonConfigPath: URL
    public let daemonBinaryPath: URL
    public let metadataDBPath: URL
    public let vectorShardPath: URL
    public let ingestionLogPath: URL
    public let metricsPath: URL

    public init(
        daemonDirectory: URL,
        indexDirectory: URL,
        cacheDirectory: URL,
        contextPacksDirectory: URL,
        logsDirectory: URL,
        socketDirectory: URL,
        launchAgentPlistPath: URL,
        daemonConfigPath: URL,
        daemonBinaryPath: URL,
        metadataDBPath: URL,
        vectorShardPath: URL,
        ingestionLogPath: URL,
        metricsPath: URL
    ) {
        self.daemonDirectory = daemonDirectory
        self.indexDirectory = indexDirectory
        self.cacheDirectory = cacheDirectory
        self.contextPacksDirectory = contextPacksDirectory
        self.logsDirectory = logsDirectory
        self.socketDirectory = socketDirectory
        self.launchAgentPlistPath = launchAgentPlistPath
        self.daemonConfigPath = daemonConfigPath
        self.daemonBinaryPath = daemonBinaryPath
        self.metadataDBPath = metadataDBPath
        self.vectorShardPath = vectorShardPath
        self.ingestionLogPath = ingestionLogPath
        self.metricsPath = metricsPath
    }

    public static func resolve() throws -> RetrievalPaths {
        let fm = FileManager.default
        let base = AppPaths.appSupportDirectory.appendingPathComponent("Retrieval", isDirectory: true)
        let daemon = base.appendingPathComponent("daemon", isDirectory: true)
        let index = base.appendingPathComponent("index", isDirectory: true)
        let cache = base.appendingPathComponent("cache", isDirectory: true)
        let packs = base.appendingPathComponent("contextpacks", isDirectory: true)
        let logs = base.appendingPathComponent("logs", isDirectory: true)
        let sockets = daemon.appendingPathComponent("sockets", isDirectory: true)
        let launchAgent = AppPaths.realHomeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("com.hivecrew.retrievald.plist")

        for directory in [base, daemon, index, cache, packs, logs, sockets] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try fm.createDirectory(at: launchAgent.deletingLastPathComponent(), withIntermediateDirectories: true)

        return RetrievalPaths(
            daemonDirectory: daemon,
            indexDirectory: index,
            cacheDirectory: cache,
            contextPacksDirectory: packs,
            logsDirectory: logs,
            socketDirectory: sockets,
            launchAgentPlistPath: launchAgent,
            daemonConfigPath: daemon.appendingPathComponent("retrieval-daemon.json"),
            daemonBinaryPath: daemon.appendingPathComponent("hivecrew-retrieval-daemon"),
            metadataDBPath: index.appendingPathComponent("metadata.db"),
            vectorShardPath: index.appendingPathComponent("vectors.jsonl"),
            ingestionLogPath: logs.appendingPathComponent("ingestion.log"),
            metricsPath: logs.appendingPathComponent("metrics.json")
        )
    }
}
