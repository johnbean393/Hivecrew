//
//  VoiceProviderBackend.swift
//  HivecrewVoice
//

import Foundation

public enum VoiceProviderBackend: String, Sendable, CaseIterable, Identifiable {
    case geminiLive = "gemini_live"
    case openAIRealtime = "openai_realtime"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .geminiLive: return "Gemini Live"
        case .openAIRealtime: return "OpenAI Realtime"
        }
    }
}
