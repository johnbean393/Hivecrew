//
//  WorkspaceSandbox.swift
//  Hivecrew
//
//  Path validation shared between Fast Worker and App Worker sessions.
//  Ensures file operations stay within approved directory roots.
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

    init(root: URL, sessionDirectories: [URL], grants: [LocalAccessGrant] = []) {
        self.root = root
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
