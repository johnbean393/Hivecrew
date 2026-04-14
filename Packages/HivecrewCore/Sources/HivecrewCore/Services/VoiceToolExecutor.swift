//
//  VoiceToolExecutor.swift
//  HivecrewCore
//

import Foundation

public struct VoiceToolCallResult: Sendable {
    public let output: String
    public let isError: Bool

    public init(output: String, isError: Bool = false) {
        self.output = output
        self.isError = isError
    }
}

@MainActor
public protocol VoiceToolExecutor: AnyObject {
    func execute(toolName: String, arguments: [String: Any]) async -> VoiceToolCallResult
    var toolDeclarations: [[String: Any]] { get }
}
