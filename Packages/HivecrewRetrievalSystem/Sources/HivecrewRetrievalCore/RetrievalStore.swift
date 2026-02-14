import Foundation
import HivecrewRetrievalProtocol
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public actor RetrievalStore {
    private let dbPath: URL
    private let contextPackDirectory: URL
    private var db: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private static let queueSnapshotMaxItems = 128
    private static let queueSnapshotRetentionCount = 1
    private static let queueSnapshotCompactThresholdBytes: Int64 = 256 * 1_024 * 1_024

    public init(dbPath: URL, contextPackDirectory: URL) {
        self.dbPath = dbPath
        self.contextPackDirectory = contextPackDirectory
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func openAndMigrate() throws {
        if db != nil {
            return
        }
        if sqlite3_open(dbPath.path, &db) != SQLITE_OK {
            throw RetrievalCoreError.sqliteError(lastError())
        }
        try exec("""
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            PRAGMA foreign_keys = ON;
            PRAGMA temp_store = MEMORY;
            CREATE TABLE IF NOT EXISTS documents (
                id TEXT PRIMARY KEY,
                source_type TEXT NOT NULL,
                source_id TEXT NOT NULL,
                title TEXT NOT NULL,
                body TEXT NOT NULL,
                source_path_or_handle TEXT NOT NULL,
                updated_at REAL NOT NULL,
                risk TEXT NOT NULL,
                partition_label TEXT NOT NULL,
                searchable INTEGER NOT NULL DEFAULT 1
            );
            CREATE UNIQUE INDEX IF NOT EXISTS idx_documents_source ON documents(source_type, source_id);
            CREATE INDEX IF NOT EXISTS idx_documents_updated_at ON documents(updated_at DESC);
            CREATE INDEX IF NOT EXISTS idx_documents_partition ON documents(partition_label);

            CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
                chunk_id UNINDEXED,
                document_id UNINDEXED,
                source_type UNINDEXED,
                title,
                text
            );

            CREATE TABLE IF NOT EXISTS chunk_vectors (
                chunk_id TEXT PRIMARY KEY,
                document_id TEXT NOT NULL,
                chunk_index INTEGER NOT NULL,
                vector_blob BLOB NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_chunk_vectors_document_id ON chunk_vectors(document_id);

            CREATE TABLE IF NOT EXISTS graph_edges (
                id TEXT PRIMARY KEY,
                source_node TEXT NOT NULL,
                target_node TEXT NOT NULL,
                edge_type TEXT NOT NULL,
                confidence REAL NOT NULL,
                weight REAL NOT NULL,
                source_type TEXT NOT NULL,
                event_time REAL,
                updated_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_graph_source ON graph_edges(source_node);
            CREATE INDEX IF NOT EXISTS idx_graph_target ON graph_edges(target_node);

            CREATE TABLE IF NOT EXISTS backfill_checkpoints (
                checkpoint_key TEXT PRIMARY KEY,
                payload_json BLOB NOT NULL,
                updated_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS backfill_jobs (
                id TEXT PRIMARY KEY,
                source_type TEXT NOT NULL,
                scope_label TEXT NOT NULL,
                status TEXT NOT NULL,
                resume_token TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS queue_snapshots (
                id TEXT PRIMARY KEY,
                payload_json BLOB NOT NULL,
                created_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_queue_snapshots_created ON queue_snapshots(created_at DESC);

            CREATE TABLE IF NOT EXISTS metrics (
                key TEXT PRIMARY KEY,
                value REAL NOT NULL,
                updated_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS audit_events (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                payload_json BLOB NOT NULL,
                created_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_audit_kind_created ON audit_events(kind, created_at DESC);

            CREATE TABLE IF NOT EXISTS ingestion_attempts (
                source_type TEXT NOT NULL,
                source_id TEXT NOT NULL,
                source_path_or_handle TEXT NOT NULL,
                updated_at REAL NOT NULL,
                outcome TEXT NOT NULL,
                attempted_at REAL NOT NULL,
                PRIMARY KEY(source_type, source_id)
            );
            CREATE INDEX IF NOT EXISTS idx_ingestion_attempts_outcome_updated
            ON ingestion_attempts(outcome, updated_at DESC);
            CREATE INDEX IF NOT EXISTS idx_ingestion_attempts_path
            ON ingestion_attempts(source_type, source_path_or_handle);
        """)
        // Backward-compatible migration for existing databases created before `searchable`.
        try? exec("ALTER TABLE documents ADD COLUMN searchable INTEGER NOT NULL DEFAULT 1;")
        try? exec("CREATE INDEX IF NOT EXISTS idx_documents_searchable ON documents(searchable);")
    }

    public func compact() throws {
        try exec("PRAGMA wal_checkpoint(TRUNCATE); VACUUM;")
    }

    public func refreshFileSearchability(nonSearchableExtensions: Set<String>) throws {
        try inTransaction {
            try execPrepared("""
                UPDATE documents
                SET searchable = 1
                WHERE source_type = ?;
            """, bind: { stmt in
                bindText(stmt, at: 1, value: RetrievalSourceType.file.rawValue)
            })

            for ext in nonSearchableExtensions.sorted() {
                try execPrepared("""
                    UPDATE documents
                    SET searchable = 0
                    WHERE source_type = ? AND lower(source_path_or_handle) LIKE ?;
                """, bind: { stmt in
                    bindText(stmt, at: 1, value: RetrievalSourceType.file.rawValue)
                    bindText(stmt, at: 2, value: "%.\(ext.lowercased())")
                })
            }

            try execPrepared("""
                DELETE FROM chunks_fts
                WHERE document_id IN (
                    SELECT id FROM documents WHERE source_type = ? AND searchable = 0
                );
            """, bind: { stmt in
                bindText(stmt, at: 1, value: RetrievalSourceType.file.rawValue)
            })

            try execPrepared("""
                DELETE FROM chunk_vectors
                WHERE document_id IN (
                    SELECT id FROM documents WHERE source_type = ? AND searchable = 0
                );
            """, bind: { stmt in
                bindText(stmt, at: 1, value: RetrievalSourceType.file.rawValue)
            })

            try execPrepared("""
                DELETE FROM graph_edges
                WHERE source_type = ? AND source_node IN (
                    SELECT id FROM documents WHERE source_type = ? AND searchable = 0
                );
            """, bind: { stmt in
                bindText(stmt, at: 1, value: RetrievalSourceType.file.rawValue)
                bindText(stmt, at: 2, value: RetrievalSourceType.file.rawValue)
            })
        }
    }

    public func upsertDocument(_ document: RetrievalDocument, chunks: [RetrievalChunk]) throws {
        try inTransaction {
            try upsertDocumentRecord(document)
            let persistedDocumentID = try persistedDocumentID(for: document)

            try execPrepared("DELETE FROM chunks_fts WHERE document_id = ?;", bind: { stmt in
                bindText(stmt, at: 1, value: persistedDocumentID)
            })
            try execPrepared("DELETE FROM chunk_vectors WHERE document_id = ?;", bind: { stmt in
                bindText(stmt, at: 1, value: persistedDocumentID)
            })

            for chunk in chunks {
                let persistedChunkID = "\(persistedDocumentID):\(chunk.index)"
                try execPrepared("""
                    INSERT INTO chunks_fts (chunk_id, document_id, source_type, title, text)
                    VALUES (?, ?, ?, ?, ?);
                """, bind: { stmt in
                    bindText(stmt, at: 1, value: persistedChunkID)
                    bindText(stmt, at: 2, value: persistedDocumentID)
                    bindText(stmt, at: 3, value: document.sourceType.rawValue)
                    bindText(stmt, at: 4, value: document.title)
                    bindText(stmt, at: 5, value: chunk.text)
                })
                let vectorBlob = try JSONEncoder().encode(chunk.embedding)
                try execPrepared("""
                    INSERT OR REPLACE INTO chunk_vectors (chunk_id, document_id, chunk_index, vector_blob)
                    VALUES (?, ?, ?, ?);
                """, bind: { stmt in
                    bindText(stmt, at: 1, value: persistedChunkID)
                    bindText(stmt, at: 2, value: persistedDocumentID)
                    sqlite3_bind_int(stmt, 3, Int32(chunk.index))
                    _ = vectorBlob.withUnsafeBytes { pointer in
                        sqlite3_bind_blob(stmt, 4, pointer.baseAddress, Int32(pointer.count), SQLITE_TRANSIENT)
                    }
                })
            }
        }
    }

    public func upsertDocumentRecord(_ document: RetrievalDocument) throws {
        try execPrepared("""
            INSERT INTO documents (id, source_type, source_id, title, body, source_path_or_handle, updated_at, risk, partition_label, searchable)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(source_type, source_id) DO UPDATE SET
                title=excluded.title,
                body=excluded.body,
                source_path_or_handle=excluded.source_path_or_handle,
                updated_at=excluded.updated_at,
                risk=excluded.risk,
                partition_label=excluded.partition_label,
                searchable=excluded.searchable;
        """, bind: { stmt in
            bindText(stmt, at: 1, value: document.id)
            bindText(stmt, at: 2, value: document.sourceType.rawValue)
            bindText(stmt, at: 3, value: document.sourceId)
            bindText(stmt, at: 4, value: document.title)
            bindText(stmt, at: 5, value: document.body)
            bindText(stmt, at: 6, value: document.sourcePathOrHandle)
            sqlite3_bind_double(stmt, 7, document.updatedAt.timeIntervalSince1970)
            bindText(stmt, at: 8, value: document.risk.rawValue)
            bindText(stmt, at: 9, value: document.partition)
            sqlite3_bind_int(stmt, 10, document.searchable ? 1 : 0)
        })
    }

    public func recordIngestionAttempt(
        sourceType: RetrievalSourceType,
        sourceId: String,
        sourcePathOrHandle: String,
        updatedAt: Date,
        outcome: ExtractionOutcomeKind
    ) throws {
        try execPrepared("""
            INSERT INTO ingestion_attempts (
                source_type,
                source_id,
                source_path_or_handle,
                updated_at,
                outcome,
                attempted_at
            )
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(source_type, source_id) DO UPDATE SET
                source_path_or_handle=excluded.source_path_or_handle,
                updated_at=excluded.updated_at,
                outcome=excluded.outcome,
                attempted_at=excluded.attempted_at;
        """, bind: { stmt in
            bindText(stmt, at: 1, value: sourceType.rawValue)
            bindText(stmt, at: 2, value: sourceId)
            bindText(stmt, at: 3, value: sourcePathOrHandle)
            sqlite3_bind_double(stmt, 4, updatedAt.timeIntervalSince1970)
            bindText(stmt, at: 5, value: outcome.rawValue)
            sqlite3_bind_double(stmt, 6, Date().timeIntervalSince1970)
        })
    }

    public func isIngestionAttemptCurrent(
        sourceType: RetrievalSourceType,
        sourceId: String,
        updatedAt: Date
    ) throws -> Bool {
        let currentTimestamp = updatedAt.timeIntervalSince1970
        let existingTimestamp = try querySingle("""
            SELECT updated_at
            FROM ingestion_attempts
            WHERE source_type = ?
              AND source_id = ?
              AND outcome IN (?, ?)
            LIMIT 1;
        """, bind: { stmt in
            bindText(stmt, at: 1, value: sourceType.rawValue)
            bindText(stmt, at: 2, value: sourceId)
            bindText(stmt, at: 3, value: ExtractionOutcomeKind.failed.rawValue)
            bindText(stmt, at: 4, value: ExtractionOutcomeKind.unsupported.rawValue)
        }, map: { stmt in
            sqlite3_column_double(stmt, 0)
        })
        guard let existingTimestamp else {
            return false
        }
        return existingTimestamp >= currentTimestamp
    }

    @discardableResult
    public func deleteDocumentsForPath(sourceType: RetrievalSourceType, sourcePathOrHandle: String) throws -> Int {
        let rawPath = sourcePathOrHandle
        let normalizedPath = URL(fileURLWithPath: sourcePathOrHandle).standardizedFileURL.resolvingSymlinksInPath().path
        let rawPrefixPattern = rawPath.hasSuffix("/") ? "\(rawPath)%" : "\(rawPath)/%"
        let prefixPattern = normalizedPath.hasSuffix("/") ? "\(normalizedPath)%" : "\(normalizedPath)/%"
        let documentIDs: [String] = try query("""
            SELECT id
            FROM documents
            WHERE source_type = ?
              AND (
                    source_id = ?
                 OR source_id = ?
                 OR source_path_or_handle = ?
                 OR source_path_or_handle = ?
                 OR source_path_or_handle LIKE ?
                 OR source_path_or_handle LIKE ?
              );
        """, bind: { stmt in
            bindText(stmt, at: 1, value: sourceType.rawValue)
            bindText(stmt, at: 2, value: rawPath)
            bindText(stmt, at: 3, value: normalizedPath)
            bindText(stmt, at: 4, value: rawPath)
            bindText(stmt, at: 5, value: normalizedPath)
            bindText(stmt, at: 6, value: rawPrefixPattern)
            bindText(stmt, at: 7, value: prefixPattern)
        }, map: { stmt in
            stringValue(stmt, at: 0)
        })
        try inTransaction {
            try execPrepared("""
                DELETE FROM ingestion_attempts
                WHERE source_type = ?
                  AND (
                        source_id = ?
                     OR source_id = ?
                     OR source_path_or_handle = ?
                     OR source_path_or_handle = ?
                     OR source_path_or_handle LIKE ?
                     OR source_path_or_handle LIKE ?
                  );
            """, bind: { stmt in
                bindText(stmt, at: 1, value: sourceType.rawValue)
                bindText(stmt, at: 2, value: rawPath)
                bindText(stmt, at: 3, value: normalizedPath)
                bindText(stmt, at: 4, value: rawPath)
                bindText(stmt, at: 5, value: normalizedPath)
                bindText(stmt, at: 6, value: rawPrefixPattern)
                bindText(stmt, at: 7, value: prefixPattern)
            })

            guard !documentIDs.isEmpty else {
                return
            }

            let batchSize = 300
            var index = 0
            while index < documentIDs.count {
                let upperBound = min(index + batchSize, documentIDs.count)
                let batch = Array(documentIDs[index..<upperBound])
                let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")

                try execPrepared("DELETE FROM chunks_fts WHERE document_id IN (\(placeholders));", bind: { stmt in
                    for (offset, id) in batch.enumerated() {
                        bindText(stmt, at: offset + 1, value: id)
                    }
                })
                try execPrepared("DELETE FROM chunk_vectors WHERE document_id IN (\(placeholders));", bind: { stmt in
                    for (offset, id) in batch.enumerated() {
                        bindText(stmt, at: offset + 1, value: id)
                    }
                })
                try execPrepared("DELETE FROM graph_edges WHERE source_node IN (\(placeholders));", bind: { stmt in
                    for (offset, id) in batch.enumerated() {
                        bindText(stmt, at: offset + 1, value: id)
                    }
                })
                try execPrepared("DELETE FROM graph_edges WHERE target_node IN (\(placeholders));", bind: { stmt in
                    for (offset, id) in batch.enumerated() {
                        bindText(stmt, at: offset + 1, value: id)
                    }
                })
                try execPrepared("DELETE FROM documents WHERE id IN (\(placeholders));", bind: { stmt in
                    for (offset, id) in batch.enumerated() {
                        bindText(stmt, at: offset + 1, value: id)
                    }
                })
                index = upperBound
            }
        }
        return documentIDs.count
    }

    private func persistedDocumentID(for document: RetrievalDocument) throws -> String {
        try querySingle("""
            SELECT id
            FROM documents
            WHERE source_type = ? AND source_id = ?
            LIMIT 1;
        """, bind: { stmt in
            bindText(stmt, at: 1, value: document.sourceType.rawValue)
            bindText(stmt, at: 2, value: document.sourceId)
        }, map: { stmt in
            stringValue(stmt, at: 0)
        }) ?? document.id
    }

    public func appendAudit(kind: String, payload: [String: String]) throws {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        try execPrepared("""
            INSERT INTO audit_events (id, kind, payload_json, created_at)
            VALUES (?, ?, ?, ?);
        """, bind: { stmt in
            bindText(stmt, at: 1, value: UUID().uuidString)
            bindText(stmt, at: 2, value: kind)
            _ = data.withUnsafeBytes { pointer in
                sqlite3_bind_blob(stmt, 3, pointer.baseAddress, Int32(pointer.count), SQLITE_TRANSIENT)
            }
            sqlite3_bind_double(stmt, 4, Date().timeIntervalSince1970)
        })
    }

    public func insertGraphEdges(_ edges: [GraphEdge]) throws {
        for edge in edges {
            try execPrepared("""
                INSERT INTO graph_edges (id, source_node, target_node, edge_type, confidence, weight, source_type, event_time, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    source_node=excluded.source_node,
                    target_node=excluded.target_node,
                    edge_type=excluded.edge_type,
                    confidence=excluded.confidence,
                    weight=excluded.weight,
                    source_type=excluded.source_type,
                    event_time=excluded.event_time,
                    updated_at=excluded.updated_at;
            """, bind: { stmt in
                bindText(stmt, at: 1, value: edge.id)
                bindText(stmt, at: 2, value: edge.sourceNode)
                bindText(stmt, at: 3, value: edge.targetNode)
                bindText(stmt, at: 4, value: edge.edgeType)
                sqlite3_bind_double(stmt, 5, edge.confidence)
                sqlite3_bind_double(stmt, 6, edge.weight)
                bindText(stmt, at: 7, value: edge.sourceType.rawValue)
                if let eventTime = edge.eventTime {
                    sqlite3_bind_double(stmt, 8, eventTime.timeIntervalSince1970)
                } else {
                    sqlite3_bind_null(stmt, 8)
                }
                sqlite3_bind_double(stmt, 9, Date().timeIntervalSince1970)
            })
        }
    }

    public func saveCheckpoint(_ checkpoint: BackfillCheckpoint) throws {
        let data = try encoder.encode(checkpoint)
        try execPrepared("""
            INSERT OR REPLACE INTO backfill_checkpoints (checkpoint_key, payload_json, updated_at)
            VALUES (?, ?, ?);
        """, bind: { stmt in
            bindText(stmt, at: 1, value: checkpoint.key)
            _ = data.withUnsafeBytes { pointer in
                sqlite3_bind_blob(stmt, 2, pointer.baseAddress, Int32(pointer.count), SQLITE_TRANSIENT)
            }
            sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
        })
    }

    public func loadCheckpoint(key: String) throws -> BackfillCheckpoint? {
        try querySingle("""
            SELECT payload_json FROM backfill_checkpoints WHERE checkpoint_key = ?;
        """, bind: { stmt in
            bindText(stmt, at: 1, value: key)
        }, map: { stmt in
            guard
                let pointer = sqlite3_column_blob(stmt, 0),
                sqlite3_column_bytes(stmt, 0) > 0
            else {
                throw RetrievalCoreError.sqliteError("Missing checkpoint payload blob")
            }
            let data = Data(bytes: pointer, count: Int(sqlite3_column_bytes(stmt, 0)))
            return try decoder.decode(BackfillCheckpoint.self, from: data)
        })
    }

    public func upsertBackfillJob(_ job: RetrievalBackfillJob) throws {
        try execPrepared("""
            INSERT INTO backfill_jobs (id, source_type, scope_label, status, resume_token, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                status=excluded.status,
                resume_token=excluded.resume_token,
                updated_at=excluded.updated_at;
        """, bind: { stmt in
            bindText(stmt, at: 1, value: job.id)
            bindText(stmt, at: 2, value: job.sourceType.rawValue)
            bindText(stmt, at: 3, value: job.scopeLabel)
            bindText(stmt, at: 4, value: job.status)
            if let token = job.resumeToken {
                bindText(stmt, at: 5, value: token)
            } else {
                sqlite3_bind_null(stmt, 5)
            }
            sqlite3_bind_double(stmt, 6, job.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 7, Date().timeIntervalSince1970)
        })
    }

    public func listBackfillJobs() throws -> [RetrievalBackfillJob] {
        try query("""
            SELECT id, source_type, scope_label, status, resume_token, created_at, updated_at
            FROM backfill_jobs
            ORDER BY updated_at DESC;
        """, map: { stmt in
            RetrievalBackfillJob(
                id: stringValue(stmt, at: 0),
                sourceType: RetrievalSourceType(rawValue: stringValue(stmt, at: 1)) ?? .file,
                scopeLabel: stringValue(stmt, at: 2),
                status: stringValue(stmt, at: 3),
                resumeToken: optionalStringValue(stmt, at: 4),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
            )
        })
    }

    public func saveQueueSnapshot(items: [IngestionEvent]) throws {
        let snapshot = Array(items.suffix(Self.queueSnapshotMaxItems))
        let data = try JSONEncoder().encode(snapshot)
        try inTransaction {
            try execPrepared("""
                INSERT INTO queue_snapshots (id, payload_json, created_at)
                VALUES (?, ?, ?);
            """, bind: { stmt in
                bindText(stmt, at: 1, value: UUID().uuidString)
                _ = data.withUnsafeBytes { pointer in
                    sqlite3_bind_blob(stmt, 2, pointer.baseAddress, Int32(pointer.count), SQLITE_TRANSIENT)
                }
                sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
            })
            try execPrepared("""
                DELETE FROM queue_snapshots
                WHERE id NOT IN (
                    SELECT id
                    FROM queue_snapshots
                    ORDER BY created_at DESC
                    LIMIT ?
                );
            """, bind: { stmt in
                sqlite3_bind_int(stmt, 1, Int32(Self.queueSnapshotRetentionCount))
            })
        }
    }

    @discardableResult
    public func reclaimQueueSnapshotStorageIfNeeded() throws -> Bool {
        let snapshotPayloadBytes = try querySingle("""
            SELECT COALESCE(SUM(length(payload_json)), 0)
            FROM queue_snapshots;
        """, map: { stmt in
            sqlite3_column_int64(stmt, 0)
        }) ?? 0
        guard snapshotPayloadBytes > 0 else {
            return false
        }
        try exec("DELETE FROM queue_snapshots;")
        if snapshotPayloadBytes >= Self.queueSnapshotCompactThresholdBytes {
            try compact()
        } else {
            try exec("PRAGMA wal_checkpoint(TRUNCATE);")
        }
        return true
    }

    public func loadLatestQueueSnapshot() throws -> [IngestionEvent] {
        let raw: Data? = try querySingle("""
            SELECT payload_json
            FROM queue_snapshots
            ORDER BY created_at DESC
            LIMIT 1;
        """, map: { stmt in
            guard
                let pointer = sqlite3_column_blob(stmt, 0),
                sqlite3_column_bytes(stmt, 0) > 0
            else {
                return Data()
            }
            return Data(bytes: pointer, count: Int(sqlite3_column_bytes(stmt, 0)))
        })
        guard let raw else { return [] }
        return try JSONDecoder().decode([IngestionEvent].self, from: raw)
    }

    public func saveContextPack(_ pack: RetrievalContextPack) throws {
        let path = contextPackDirectory.appendingPathComponent("\(pack.id).json")
        let data = try JSONEncoder().encode(pack)
        try data.write(to: path, options: .atomic)
    }

    public func loadContextPack(id: String) throws -> RetrievalContextPack? {
        let path = contextPackDirectory.appendingPathComponent("\(id).json")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let data = try Data(contentsOf: path)
        return try JSONDecoder().decode(RetrievalContextPack.self, from: data)
    }

    public func fetchDocument(for id: String) throws -> RetrievalDocument? {
        try querySingle("""
            SELECT id, source_type, source_id, title, body, source_path_or_handle, updated_at, risk, partition_label, searchable
            FROM documents WHERE id = ?;
        """, bind: { stmt in
            bindText(stmt, at: 1, value: id)
        }, map: { stmt in
            RetrievalDocument(
                id: stringValue(stmt, at: 0),
                sourceType: RetrievalSourceType(rawValue: stringValue(stmt, at: 1)) ?? .file,
                sourceId: stringValue(stmt, at: 2),
                title: stringValue(stmt, at: 3),
                body: stringValue(stmt, at: 4),
                sourcePathOrHandle: stringValue(stmt, at: 5),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6)),
                risk: RetrievalRiskLabel(rawValue: stringValue(stmt, at: 7)) ?? .low,
                partition: stringValue(stmt, at: 8),
                searchable: sqlite3_column_int(stmt, 9) == 1
            )
        })
    }

    public func isDocumentCurrent(sourceType: RetrievalSourceType, sourceId: String, updatedAt: Date) throws -> Bool {
        let currentTimestamp = updatedAt.timeIntervalSince1970
        let existingTimestamp = try querySingle("""
            SELECT updated_at
            FROM documents
            WHERE source_type = ? AND source_id = ?
            LIMIT 1;
        """, bind: { stmt in
            bindText(stmt, at: 1, value: sourceType.rawValue)
            bindText(stmt, at: 2, value: sourceId)
        }, map: { stmt in
            sqlite3_column_double(stmt, 0)
        })
        guard let existingTimestamp else {
            return false
        }
        return existingTimestamp >= currentTimestamp
    }

    public func lexicalSearch(
        queryText: String,
        sourceFilters: Set<RetrievalSourceType>,
        partitionFilter: Set<String>,
        limit: Int
    ) throws -> [LexicalHit] {
        var sql = """
            SELECT d.id, d.source_type, d.title, d.source_path_or_handle, d.risk, d.updated_at, c.text
            FROM chunks_fts c
            JOIN documents d ON d.id = c.document_id
            WHERE chunks_fts MATCH ?
              AND d.searchable = 1
        """
        var binders: [(OpaquePointer) -> Void] = [
            { stmt in bindText(stmt, at: 1, value: queryText) }
        ]
        var index = 2

        if !sourceFilters.isEmpty {
            let placeholders = Array(repeating: "?", count: sourceFilters.count).joined(separator: ",")
            sql += " AND d.source_type IN (\(placeholders))"
            for source in sourceFilters.sorted(by: { $0.rawValue < $1.rawValue }) {
                let localIndex = index
                binders.append { stmt in bindText(stmt, at: localIndex, value: source.rawValue) }
                index += 1
            }
        }

        if !partitionFilter.isEmpty {
            let placeholders = Array(repeating: "?", count: partitionFilter.count).joined(separator: ",")
            sql += " AND d.partition_label IN (\(placeholders))"
            for partition in partitionFilter.sorted() {
                let localIndex = index
                binders.append { stmt in bindText(stmt, at: localIndex, value: partition) }
                index += 1
            }
        }

        sql += " ORDER BY bm25(chunks_fts) LIMIT ?;"
        let limitIndex = index
        binders.append { stmt in sqlite3_bind_int(stmt, Int32(limitIndex), Int32(limit)) }

        return try query(sql, bind: { stmt in
            binders.forEach { $0(stmt) }
        }, map: { stmt in
            LexicalHit(
                documentId: stringValue(stmt, at: 0),
                sourceType: RetrievalSourceType(rawValue: stringValue(stmt, at: 1)) ?? .file,
                title: stringValue(stmt, at: 2),
                sourcePathOrHandle: stringValue(stmt, at: 3),
                risk: RetrievalRiskLabel(rawValue: stringValue(stmt, at: 4)) ?? .low,
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)),
                snippet: stringValue(stmt, at: 6)
            )
        })
    }

    public func allChunkVectors(
        sourceFilters: Set<RetrievalSourceType>,
        partitionFilter: Set<String>,
        limit: Int
    ) throws -> [VectorHit] {
        var sql = """
            SELECT v.chunk_id, v.document_id, v.chunk_index, v.vector_blob, d.source_type, d.title, d.source_path_or_handle, d.risk, d.updated_at
            FROM chunk_vectors v
            JOIN documents d ON d.id = v.document_id
            WHERE d.searchable = 1
        """

        var binders: [(OpaquePointer) -> Void] = []
        var bindIndex = 1

        if !sourceFilters.isEmpty {
            let placeholders = Array(repeating: "?", count: sourceFilters.count).joined(separator: ",")
            sql += " AND d.source_type IN (\(placeholders))"
            for source in sourceFilters.sorted(by: { $0.rawValue < $1.rawValue }) {
                let localIndex = bindIndex
                binders.append { stmt in bindText(stmt, at: localIndex, value: source.rawValue) }
                bindIndex += 1
            }
        }

        if !partitionFilter.isEmpty {
            let placeholders = Array(repeating: "?", count: partitionFilter.count).joined(separator: ",")
            sql += " AND d.partition_label IN (\(placeholders))"
            for partition in partitionFilter.sorted() {
                let localIndex = bindIndex
                binders.append { stmt in bindText(stmt, at: localIndex, value: partition) }
                bindIndex += 1
            }
        }

        sql += " ORDER BY d.updated_at DESC LIMIT ?;"
        let limitIndex = bindIndex
        binders.append { stmt in sqlite3_bind_int(stmt, Int32(limitIndex), Int32(limit)) }

        return try query(sql, bind: { stmt in
            binders.forEach { $0(stmt) }
        }, map: { stmt in
            let vectorData = blobData(stmt, at: 3)
            let vector = (try? JSONDecoder().decode([Float].self, from: vectorData)) ?? []
            return VectorHit(
                chunkId: stringValue(stmt, at: 0),
                documentId: stringValue(stmt, at: 1),
                chunkIndex: Int(sqlite3_column_int(stmt, 2)),
                vector: vector,
                sourceType: RetrievalSourceType(rawValue: stringValue(stmt, at: 4)) ?? .file,
                title: stringValue(stmt, at: 5),
                sourcePathOrHandle: stringValue(stmt, at: 6),
                risk: RetrievalRiskLabel(rawValue: stringValue(stmt, at: 7)) ?? .low,
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8))
            )
        })
    }

    public func graphNeighbors(seedDocumentIds: Set<String>, maxEdges: Int) throws -> [GraphEdge] {
        guard !seedDocumentIds.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: seedDocumentIds.count).joined(separator: ",")
        let sql = """
            SELECT id, source_node, target_node, edge_type, confidence, weight, source_type, event_time, updated_at
            FROM graph_edges
            WHERE source_node IN (\(placeholders)) OR target_node IN (\(placeholders))
            ORDER BY confidence DESC, updated_at DESC
            LIMIT ?;
        """

        let sorted = seedDocumentIds.sorted()
        return try query(sql, bind: { stmt in
            var index = 1
            for node in sorted {
                bindText(stmt, at: index, value: node)
                index += 1
            }
            for node in sorted {
                bindText(stmt, at: index, value: node)
                index += 1
            }
            sqlite3_bind_int(stmt, Int32(index), Int32(maxEdges))
        }, map: { stmt in
            let eventTime: Date?
            if sqlite3_column_type(stmt, 7) == SQLITE_NULL {
                eventTime = nil
            } else {
                eventTime = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))
            }
            return GraphEdge(
                id: stringValue(stmt, at: 0),
                sourceNode: stringValue(stmt, at: 1),
                targetNode: stringValue(stmt, at: 2),
                edgeType: stringValue(stmt, at: 3),
                confidence: sqlite3_column_double(stmt, 4),
                weight: sqlite3_column_double(stmt, 5),
                sourceType: RetrievalSourceType(rawValue: stringValue(stmt, at: 6)) ?? .file,
                eventTime: eventTime,
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8))
            )
        })
    }

    public func allProgressStates() throws -> [RetrievalProgressState] {
        let checkpoints: [BackfillCheckpoint] = try query("""
            SELECT payload_json FROM backfill_checkpoints ORDER BY updated_at DESC;
        """, map: { stmt in
            let data = blobData(stmt, at: 0)
            return try decoder.decode(BackfillCheckpoint.self, from: data)
        })
        return checkpoints.map {
            let completion: Double
            if $0.status.lowercased().contains("idle"), $0.itemsProcessed > 0 {
                completion = 1
            } else {
                completion = $0.estimatedTotal > 0 ? (Double($0.itemsProcessed) / Double($0.estimatedTotal)) : 0
            }
            return RetrievalProgressState(
                sourceType: $0.sourceType,
                scopeLabel: $0.scopeLabel,
                status: $0.status,
                itemsProcessed: $0.itemsProcessed,
                itemsSkipped: $0.itemsSkipped,
                estimatedTotal: $0.estimatedTotal,
                percentComplete: min(1, max(0, completion)),
                etaSeconds: estimateETA(for: $0),
                checkpointUpdatedAt: $0.updatedAt
            )
        }
    }

    public func indexStats() throws -> RetrievalIndexStats {
        let rows: [(sourceType: String, count: Int, latestUpdatedAt: Date?)] = try query("""
            SELECT source_type, COUNT(*) AS document_count, MAX(updated_at) AS latest_updated_at
            FROM documents
            GROUP BY source_type;
        """, map: { stmt in
            let latestUpdatedAt: Date?
            if sqlite3_column_type(stmt, 2) == SQLITE_NULL {
                latestUpdatedAt = nil
            } else {
                latestUpdatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
            }
            return (
                sourceType: stringValue(stmt, at: 0),
                count: Int(sqlite3_column_int(stmt, 1)),
                latestUpdatedAt: latestUpdatedAt
            )
        })

        var bySource: [RetrievalSourceType: RetrievalIndexedSourceStats] = [:]
        for row in rows {
            guard let sourceType = RetrievalSourceType(rawValue: row.sourceType) else { continue }
            bySource[sourceType] = RetrievalIndexedSourceStats(
                sourceType: sourceType,
                documentCount: row.count,
                lastDocumentUpdatedAt: row.latestUpdatedAt
            )
        }

        let sources = RetrievalSourceType.allCases.map { sourceType in
            bySource[sourceType] ?? RetrievalIndexedSourceStats(
                sourceType: sourceType,
                documentCount: 0,
                lastDocumentUpdatedAt: nil
            )
        }
        let totalDocumentCount = sources.reduce(0) { $0 + $1.documentCount }
        return RetrievalIndexStats(totalDocumentCount: totalDocumentCount, sources: sources)
    }

    private func estimateETA(for checkpoint: BackfillCheckpoint) -> Int? {
        guard checkpoint.estimatedTotal > 0 else { return nil }
        guard checkpoint.itemsProcessed > 0 else { return nil }
        let elapsed = Date().timeIntervalSince(checkpoint.updatedAt) + 1
        let rate = Double(checkpoint.itemsProcessed) / max(elapsed, 1)
        guard rate > 0.01 else { return nil }
        let remaining = max(0, checkpoint.estimatedTotal - checkpoint.itemsProcessed)
        return Int(Double(remaining) / rate)
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw RetrievalCoreError.sqliteError(lastError())
        }
    }

    private func execPrepared(_ sql: String, bind: ((OpaquePointer) -> Void)? = nil) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw RetrievalCoreError.sqliteError(lastError())
        }
        defer { sqlite3_finalize(statement) }
        if let statement, let bind {
            bind(statement)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RetrievalCoreError.sqliteError(lastError())
        }
    }

    private func query<T>(
        _ sql: String,
        bind: ((OpaquePointer) -> Void)? = nil,
        map: (OpaquePointer) throws -> T
    ) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw RetrievalCoreError.sqliteError(lastError())
        }
        defer { sqlite3_finalize(statement) }

        if let statement, let bind {
            bind(statement)
        }

        var values: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let statement else { break }
            values.append(try map(statement))
        }
        return values
    }

    private func querySingle<T>(
        _ sql: String,
        bind: ((OpaquePointer) -> Void)? = nil,
        map: (OpaquePointer) throws -> T
    ) throws -> T? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw RetrievalCoreError.sqliteError(lastError())
        }
        defer { sqlite3_finalize(statement) }

        if let statement, let bind {
            bind(statement)
        }

        if sqlite3_step(statement) == SQLITE_ROW, let statement {
            return try map(statement)
        }
        return nil
    }

    private func inTransaction(_ body: () throws -> Void) throws {
        try exec("BEGIN TRANSACTION;")
        do {
            try body()
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    private func lastError() -> String {
        guard let db, let cString = sqlite3_errmsg(db) else { return "Unknown sqlite error" }
        return String(cString: cString)
    }
}

private func bindText(_ stmt: OpaquePointer, at index: Int, value: String) {
    sqlite3_bind_text(stmt, Int32(index), value, -1, SQLITE_TRANSIENT)
}

private func stringValue(_ stmt: OpaquePointer, at index: Int32) -> String {
    guard let cString = sqlite3_column_text(stmt, index) else { return "" }
    return String(cString: cString)
}

private func optionalStringValue(_ stmt: OpaquePointer, at index: Int32) -> String? {
    guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
    return stringValue(stmt, at: index)
}

private func blobData(_ stmt: OpaquePointer, at index: Int32) -> Data {
    guard
        let pointer = sqlite3_column_blob(stmt, index),
        sqlite3_column_bytes(stmt, index) > 0
    else {
        return Data()
    }
    return Data(bytes: pointer, count: Int(sqlite3_column_bytes(stmt, index)))
}
