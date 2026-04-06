//
//  VoiceTranscription.swift
//  HivecrewVoice
//

import Foundation

public struct VoiceTranscription: Sendable {
    public enum Source: Sendable {
        case input
        case output
    }

    public let source: Source
    public let text: String

    public init(source: Source, text: String) {
        self.source = source
        self.text = text
    }
}
