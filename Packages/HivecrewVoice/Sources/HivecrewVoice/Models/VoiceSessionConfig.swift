//
//  VoiceSessionConfig.swift
//  HivecrewVoice
//

import Foundation

public struct VoiceSessionConfig: Sendable {
    public var systemPrompt: String?
    public var voiceName: String?
    public var tools: [VoiceToolDeclaration]
    public var mediaResolution: MediaResolution
    public var thinkingLevel: ThinkingLevel
    public var includeThoughts: Bool
    public var webSearchEnabled: Bool
    public var providerSpecific: [String: String]

    public init(
        systemPrompt: String? = nil,
        voiceName: String? = nil,
        tools: [VoiceToolDeclaration] = [],
        mediaResolution: MediaResolution = .medium,
        thinkingLevel: ThinkingLevel = .low,
        includeThoughts: Bool = true,
        webSearchEnabled: Bool = true,
        providerSpecific: [String: String] = [:]
    ) {
        self.systemPrompt = systemPrompt
        self.voiceName = voiceName
        self.tools = tools
        self.mediaResolution = mediaResolution
        self.thinkingLevel = thinkingLevel
        self.includeThoughts = includeThoughts
        self.webSearchEnabled = webSearchEnabled
        self.providerSpecific = providerSpecific
    }

    public enum MediaResolution: String, Sendable, CaseIterable, Identifiable {
        case low = "low"
        case medium = "medium"
        case high = "high"

        public var id: String { rawValue }
    }

    public enum ThinkingLevel: String, Sendable, CaseIterable, Identifiable {
        case minimal = "minimal"
        case low = "low"
        case medium = "medium"
        case high = "high"

        public var id: String { rawValue }
    }
}
