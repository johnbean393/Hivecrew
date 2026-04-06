//
//  VoiceToolCall.swift
//  HivecrewVoice
//

import Foundation

public struct VoiceToolCall: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let arguments: [String: String]

    public init(id: String, name: String, arguments: [String: String]) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}
