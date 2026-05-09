//
//  WorkspaceSandbox.swift
//  Hivecrew
//
//  Path resolution shared between Fast Worker and App Worker sessions.
//  Relative paths resolve from the session root so inbox/, workspace/, and
//  outbox/ remain stable while absolute host paths remain available.
//

import Foundation
import HivecrewCore

enum WorkspaceSandboxError: Error, LocalizedError {
    case pathOutsideApprovedRoot(String)

    var errorDescription: String? {
        switch self {
        case .pathOutsideApprovedRoot(let path):
            return "Path '\(path)' is outside approved session roots."
        }
    }
}

struct WorkspaceSandbox: Sendable {

    let root: URL
    let approvedRoots: [URL]
    let allowsHostFilesystemAccess: Bool

    init(
        root: URL,
        sessionDirectories: [URL],
        grants: [LocalAccessGrant] = [],
        allowsHostFilesystemAccess: Bool = false
    ) {
        self.root = root
        self.allowsHostFilesystemAccess = allowsHostFilesystemAccess
        var roots = sessionDirectories
        for grant in grants {
            let url = URL(fileURLWithPath: grant.rootPath).standardizedFileURL
            roots.append(url)
        }
        self.approvedRoots = roots
    }

    func validatePath(_ rawPath: String) throws -> URL {
        let resolved = URL(fileURLWithPath: rawPath, relativeTo: root)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        if allowsHostFilesystemAccess {
            return resolved
        }
        for root in approvedRoots {
            let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
            if resolved.path == rootPath || resolved.path.hasPrefix(rootPath + "/") {
                return resolved
            }
        }
        throw WorkspaceSandboxError.pathOutsideApprovedRoot(rawPath)
    }

    func isPathAllowed(_ rawPath: String) -> Bool {
        (try? validatePath(rawPath)) != nil
    }
}
