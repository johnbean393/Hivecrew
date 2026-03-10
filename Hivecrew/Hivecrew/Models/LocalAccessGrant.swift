//
//  LocalAccessGrant.swift
//  Hivecrew
//
//  Persisted local filesystem grants for staged writeback operations.
//

import Foundation

enum LocalAccessScopeKind: String, Codable, CaseIterable, Sendable {
    case file
    case folder
}

enum LocalAccessGrantOrigin: String, Codable, Sendable {
    case attachment
    case explicitGrant = "explicit_grant"
}

enum LocalAccessGrantMode: String, Codable, Sendable {
    case readWrite = "read_write"
}

struct LocalAccessGrant: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var scopeKind: LocalAccessScopeKind
    var displayName: String
    var rootPath: String
    var bookmarkData: Data?
    var origin: LocalAccessGrantOrigin
    var accessMode: LocalAccessGrantMode

    init(
        id: UUID = UUID(),
        scopeKind: LocalAccessScopeKind,
        displayName: String,
        rootPath: String,
        bookmarkData: Data? = nil,
        origin: LocalAccessGrantOrigin,
        accessMode: LocalAccessGrantMode = .readWrite
    ) {
        self.id = id
        self.scopeKind = scopeKind
        self.displayName = displayName
        self.rootPath = rootPath
        self.bookmarkData = bookmarkData
        self.origin = origin
        self.accessMode = accessMode
    }

    var rootURL: URL {
        URL(fileURLWithPath: rootPath)
    }

    var normalizedRootPath: String {
        rootURL.standardizedFileURL.path
    }

    func allowsAccess(to destinationPath: String) -> Bool {
        let candidateURL = URL(fileURLWithPath: destinationPath).standardizedFileURL
        let candidatePath = candidateURL.path

        switch scopeKind {
        case .file:
            return candidatePath == normalizedRootPath
        case .folder:
            return candidatePath == normalizedRootPath
                || candidatePath.hasPrefix(normalizedRootPath + "/")
        }
    }

    static func make(from url: URL, origin: LocalAccessGrantOrigin) -> LocalAccessGrant {
        let standardizedURL = url.standardizedFileURL
        let bookmarkData: Data?
        if standardizedURL.startAccessingSecurityScopedResource() {
            bookmarkData = try? standardizedURL.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            standardizedURL.stopAccessingSecurityScopedResource()
        } else {
            bookmarkData = try? standardizedURL.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }

        let scopeKind: LocalAccessScopeKind = standardizedURL.hasDirectoryPath ? .folder : .file
        return LocalAccessGrant(
            scopeKind: scopeKind,
            displayName: standardizedURL.lastPathComponent,
            rootPath: standardizedURL.path,
            bookmarkData: bookmarkData,
            origin: origin
        )
    }
}
