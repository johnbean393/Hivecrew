//
//  SwiftDataStoreManager.swift
//  Hivecrew
//
//  Pins SwiftData to a canonical on-disk location and migrates legacy stores.
//

import Foundation
import OSLog
import SQLite3
import SwiftData
import HivecrewShared

enum SwiftDataStoreManager {
    static let storeFileName = "default.store"
    static let storeFileNames = [
        "default.store",
        "default.store-wal",
        "default.store-shm",
    ]

    static let storeDirectory: URL = {
        let url = AppPaths.appSupportDirectory.appendingPathComponent("SwiftData", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let storeURL = storeDirectory.appendingPathComponent(storeFileName)

    private static let autoSnapshotDirectory: URL = {
        let url = AppPaths.appSupportDirectory
            .appendingPathComponent("Backups", isDirectory: true)
            .appendingPathComponent("SwiftData", isDirectory: true)
            .appendingPathComponent("AutoSnapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static let corruptedStoreDirectory: URL = {
        let url = AppPaths.appSupportDirectory
            .appendingPathComponent("Backups", isDirectory: true)
            .appendingPathComponent("SwiftData", isDirectory: true)
            .appendingPathComponent("CorruptedStores", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.pattonium.Hivecrew",
        category: "SwiftData"
    )

    static func makeModelContainer(schema: Schema) throws -> ModelContainer {
        try prepareStoreIfNeeded()

        do {
            return try buildContainer(schema: schema)
        } catch {
            logger.error("SwiftData open failed for canonical store at \(storeURL.path, privacy: .public): \(String(describing: error), privacy: .public)")

            guard try restoreLatestSnapshotIfNeeded() else {
                throw error
            }

            logger.notice("Recovered SwiftData store from the latest automatic snapshot")
            return try buildContainer(schema: schema)
        }
    }

    private static func buildContainer(schema: Schema) throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, url: storeURL)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private static func prepareStoreIfNeeded() throws {
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        try migrateLegacyStoreIfNeeded()
        try createAutomaticSnapshotIfNeeded()
    }

    private static func migrateLegacyStoreIfNeeded() throws {
        let canonicalStore = inspectStore(in: storeDirectory)
        let bestLegacyStore = legacyStoreDirectories()
            .compactMap { inspectStore(in: $0) }
            .sorted { lhs, rhs in
                isPreferredStore(lhs, rhs)
            }
            .first

        guard let bestLegacyStore else { return }

        if canonicalStore == nil {
            try copyStoreFiles(from: bestLegacyStore.directory, to: storeDirectory, replaceExisting: false)
            logger.notice("Migrated SwiftData store from \(bestLegacyStore.directory.path, privacy: .public) to \(storeDirectory.path, privacy: .public)")
            return
        }

        guard let canonicalStore,
              canonicalStore.recordCount == 0,
              bestLegacyStore.recordCount > 0
        else {
            return
        }

        try archiveCurrentStore(reason: "empty-canonical")
        try copyStoreFiles(from: bestLegacyStore.directory, to: storeDirectory, replaceExisting: true)
        logger.notice("Replaced empty canonical SwiftData store with legacy store from \(bestLegacyStore.directory.path, privacy: .public)")
    }

    private static func createAutomaticSnapshotIfNeeded() throws {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }

        let snapshotDirectory = autoSnapshotDirectory.appendingPathComponent(timestampTag(), isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
        try copyStoreFiles(from: storeDirectory, to: snapshotDirectory, replaceExisting: false)
        try pruneSnapshots(keeping: 5)
    }

    private static func restoreLatestSnapshotIfNeeded() throws -> Bool {
        let snapshots = try FileManager.default.contentsOfDirectory(
            at: autoSnapshotDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let latestSnapshot = snapshots
            .filter { inspectStore(in: $0) != nil }
            .sorted { lhs, rhs in
                modificationDate(for: lhs) > modificationDate(for: rhs)
            }
            .first

        guard let latestSnapshot else { return false }

        try archiveCurrentStore(reason: "failed-open")
        try copyStoreFiles(from: latestSnapshot, to: storeDirectory, replaceExisting: true)
        return true
    }

    private static func pruneSnapshots(keeping maxCount: Int) throws {
        let snapshots = try FileManager.default.contentsOfDirectory(
            at: autoSnapshotDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let sortedSnapshots = snapshots.sorted { lhs, rhs in
            modificationDate(for: lhs) > modificationDate(for: rhs)
        }

        guard sortedSnapshots.count > maxCount else { return }

        for snapshot in sortedSnapshots.dropFirst(maxCount) {
            try? FileManager.default.removeItem(at: snapshot)
        }
    }

    private static func archiveCurrentStore(reason: String) throws {
        let existingFiles = existingStoreFiles(in: storeDirectory)
        guard !existingFiles.isEmpty else { return }

        let archiveDirectory = corruptedStoreDirectory.appendingPathComponent(
            "\(reason)-\(timestampTag())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)

        for fileURL in existingFiles {
            let destinationURL = archiveDirectory.appendingPathComponent(fileURL.lastPathComponent)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: fileURL, to: destinationURL)
        }
    }

    private static func copyStoreFiles(from sourceDirectory: URL, to destinationDirectory: URL, replaceExisting: Bool) throws {
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        var copiedPrimaryStore = false

        for fileName in storeFileNames {
            let sourceURL = sourceDirectory.appendingPathComponent(fileName)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else { continue }

            let destinationURL = destinationDirectory.appendingPathComponent(fileName)
            if replaceExisting, FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

            if fileName == storeFileName {
                copiedPrimaryStore = true
            }
        }

        guard copiedPrimaryStore else {
            throw CocoaError(.fileNoSuchFile)
        }
    }

    private static func existingStoreFiles(in directory: URL) -> [URL] {
        storeFileNames.compactMap { fileName in
            let fileURL = directory.appendingPathComponent(fileName)
            return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
        }
    }

    private static func legacyStoreDirectories() -> [URL] {
        var directories: [URL] = []
        let fileManager = FileManager.default

        if let appSupportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            directories.append(appSupportDirectory)
        }

        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            let containerDirectory = AppPaths.realHomeDirectory
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Containers", isDirectory: true)
                .appendingPathComponent(bundleIdentifier, isDirectory: true)
                .appendingPathComponent("Data", isDirectory: true)
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
            directories.append(containerDirectory)
        }

        return Array(Set(directories)).filter { $0.standardizedFileURL != storeDirectory.standardizedFileURL }
    }

    private static func inspectStore(in directory: URL) -> StoreInspection? {
        let primaryStoreURL = directory.appendingPathComponent(storeFileName)
        guard FileManager.default.fileExists(atPath: primaryStoreURL.path) else { return nil }

        let existingFiles = existingStoreFiles(in: directory)
        let totalBytes = existingFiles.reduce(into: Int64(0)) { partialResult, fileURL in
            partialResult += fileSize(for: fileURL)
        }

        let tableCounts = readTableCounts(from: primaryStoreURL)
        return StoreInspection(
            directory: directory,
            recordCount: tableCounts.providers + tableCounts.tasks,
            latestModificationDate: existingFiles.map { modificationDate(for: $0) }.max() ?? .distantPast,
            totalBytes: totalBytes
        )
    }

    private static func isPreferredStore(_ lhs: StoreInspection, _ rhs: StoreInspection) -> Bool {
        if lhs.recordCount != rhs.recordCount {
            return lhs.recordCount > rhs.recordCount
        }
        if lhs.latestModificationDate != rhs.latestModificationDate {
            return lhs.latestModificationDate > rhs.latestModificationDate
        }
        return lhs.totalBytes > rhs.totalBytes
    }

    private static func readTableCounts(from storeURL: URL) -> (providers: Int, tasks: Int) {
        var database: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let database {
                sqlite3_close(database)
            }
            return (0, 0)
        }
        defer { sqlite3_close(database) }

        return (
            providers: countRows(in: "ZLLMPROVIDERRECORD", database: database),
            tasks: countRows(in: "ZTASKRECORD", database: database)
        )
    }

    private static func countRows(in table: String, database: OpaquePointer?) -> Int {
        guard tableExists(table, database: database) else { return 0 }

        let query = "SELECT COUNT(*) FROM \(table)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            return 0
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    private static func tableExists(_ table: String, database: OpaquePointer?) -> Bool {
        let query = "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, table, -1, sqliteTransientDestructorType)
        guard sqlite3_step(statement) == SQLITE_ROW else { return false }
        return sqlite3_column_int(statement, 0) > 0
    }

    private static func fileSize(for url: URL) -> Int64 {
        let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        return size?.int64Value ?? 0
    }

    private static func modificationDate(for url: URL) -> Date {
        let date = try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        return date ?? .distantPast
    }

    private static func timestampTag() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

private let sqliteTransientDestructorType = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private struct StoreInspection: Hashable {
    let directory: URL
    let recordCount: Int
    let latestModificationDate: Date
    let totalBytes: Int64
}
