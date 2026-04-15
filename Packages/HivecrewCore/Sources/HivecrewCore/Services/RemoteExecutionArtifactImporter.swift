//
//  RemoteExecutionArtifactImporter.swift
//  HivecrewCore
//
//  Downloads remote execution artifacts (outputs, trace bundles) from peers via `PeerAPIClient`
//  and writes them with Foundation file I/O.
//

import Foundation
import HivecrewAPIModels

/// Downloads output files and trace bundles from a peer worker and writes them under caller-provided URLs.
public struct RemoteExecutionArtifactImporter: Sendable {
    // MARK: - Output files

    /// Merges file lists from the task snapshot and a live directory listing (same logic as macOS federated provider).
    public static func mergedRemoteOutputFiles(
        snapshotFiles: [APIFile],
        listedFiles: [APIFileDetail]
    ) -> [APIFile] {
        var seenNames: Set<String> = []
        var merged: [APIFile] = []

        for file in snapshotFiles {
            if seenNames.insert(file.name).inserted {
                merged.append(file)
            }
        }

        for file in listedFiles {
            if seenNames.insert(file.name).inserted {
                merged.append(APIFile(name: file.name, size: file.size, mimeType: file.mimeType))
            }
        }

        return merged
    }

    /// Fetches merged remote output blobs for a completed worker task.
    public static func downloadRemoteOutputFiles(
        client: PeerAPIClient,
        workerTaskId: String,
        canonicalTaskId: String,
        remoteTaskSnapshot: APITask
    ) async throws -> [(name: String, data: Data)] {
        let listedOutputFiles = try? await client.getTaskFiles(taskId: workerTaskId, canonicalTaskId: canonicalTaskId).outputFiles
        let remoteOutputFiles = mergedRemoteOutputFiles(
            snapshotFiles: remoteTaskSnapshot.outputFiles,
            listedFiles: listedOutputFiles ?? []
        )

        guard !remoteOutputFiles.isEmpty else {
            return []
        }

        var downloads: [(name: String, data: Data)] = []
        downloads.reserveCapacity(remoteOutputFiles.count)

        for file in remoteOutputFiles {
            do {
                let blob = try await client.downloadTaskFile(taskId: workerTaskId, filename: file.name, isInput: false)
                downloads.append((name: file.name, data: blob.data))
            } catch {
                // Skip files that fail (e.g. directories listed as output files).
                continue
            }
        }

        return downloads
    }

    // MARK: - Trace bundle

    /// Returns whether `trace.jsonl` already exists under `sessionDirectory`.
    public static func traceJsonlExists(in sessionDirectory: URL) -> Bool {
        let traceFile = sessionDirectory.appendingPathComponent("trace.jsonl")
        return FileManager.default.fileExists(atPath: traceFile.path)
    }

    /// Downloads every file from the worker trace bundle into `sessionDirectory`, then rewrites path references in `trace.jsonl`.
    ///
    /// - Parameters:
    ///   - canonicalTaskId: Canonical owner task id (used for `getTraceBundle` response metadata).
    public static func downloadTraceBundleToSessionDirectory(
        client: PeerAPIClient,
        workerTaskId: String,
        canonicalTaskId: String,
        sessionDirectory: URL
    ) async throws {
        if traceJsonlExists(in: sessionDirectory) {
            return
        }

        let bundle = try await client.getTraceBundle(taskId: workerTaskId, canonicalTaskId: canonicalTaskId)

        let fm = FileManager.default
        try? fm.removeItem(at: sessionDirectory)
        try fm.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)

        for file in bundle.files {
            let blob = try await client.downloadTraceFile(taskId: workerTaskId, relativePath: file.path)
            let destination = sessionDirectory.appendingPathComponent(file.path)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try blob.data.write(to: destination, options: .atomic)
        }

        rewriteImportedTracePaths(in: sessionDirectory)
    }

    /// Rewrites screenshot / nested trace paths inside imported `trace.jsonl` files so they point at files under `sessionDirectory`.
    public static func rewriteImportedTracePaths(in sessionDirectory: URL) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: sessionDirectory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return
        }

        for case let fileURL as URL in enumerator where fileURL.lastPathComponent == "trace.jsonl" {
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let rewritten = rewriteTraceJSONL(content, sessionDirectory: sessionDirectory)
            guard rewritten != content else { continue }
            try? rewritten.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    private static func rewriteTraceJSONL(_ content: String, sessionDirectory: URL) -> String {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.map { line in
            guard let data = String(line).data(using: .utf8),
                  var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  var eventData = json["data"] as? [String: Any] else {
                return String(line)
            }

            if var observation = eventData["observation"] as? [String: Any],
               var inner = observation["_0"] as? [String: Any],
               let screenshotPath = inner["screenshotPath"] as? String,
               let localizedPath = localizeImportedPath(screenshotPath, sessionDirectory: sessionDirectory) {
                inner["screenshotPath"] = localizedPath
                observation["_0"] = inner
                eventData["observation"] = observation
            }

            if var custom = eventData["custom"] as? [String: Any] {
                if var inner = custom["_0"] as? [String: Any],
                   let tracePath = inner["trace_path"] as? String,
                   let localizedTracePath = localizeImportedPath(tracePath, sessionDirectory: sessionDirectory, allowRelative: true) {
                    inner["trace_path"] = localizedTracePath
                    custom["_0"] = inner
                    eventData["custom"] = custom
                } else if let tracePath = custom["trace_path"] as? String,
                          let localizedTracePath = localizeImportedPath(tracePath, sessionDirectory: sessionDirectory, allowRelative: true) {
                    custom["trace_path"] = localizedTracePath
                    eventData["custom"] = custom
                }
            }

            json["data"] = eventData
            guard let rewrittenData = try? JSONSerialization.data(withJSONObject: json),
                  let rewrittenLine = String(data: rewrittenData, encoding: .utf8) else {
                return String(line)
            }
            return rewrittenLine
        }
        .joined(separator: "\n")
    }

    private static func localizeImportedPath(
        _ rawPath: String,
        sessionDirectory: URL,
        allowRelative: Bool = false
    ) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if allowRelative, !trimmed.hasPrefix("/") {
            return trimmed
        }

        let candidates = ["subagents/", "screenshots/"]
        for marker in candidates {
            if let range = trimmed.range(of: marker) {
                let suffix = String(trimmed[range.lowerBound...])
                return sessionDirectory.appendingPathComponent(suffix).path
            }
        }

        let filename = URL(fileURLWithPath: trimmed).lastPathComponent
        if !filename.isEmpty {
            let screenshotCandidate = sessionDirectory.appendingPathComponent("screenshots").appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: screenshotCandidate.path) {
                return screenshotCandidate.path
            }
        }

        return nil
    }
}
