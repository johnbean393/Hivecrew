//
//  RealtimeVoiceCatalog.swift
//  HivecrewVoice
//
//  Shared provider voice catalogs used by app settings UIs.
//

import Foundation

public struct RealtimeVoiceOption: Sendable, Hashable, Identifiable {
    public let id: String
    public let displayName: String
    public let descriptor: String?

    public init(id: String, displayName: String, descriptor: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.descriptor = descriptor
    }
}

public struct RealtimeVoiceModelOption: Sendable, Hashable, Identifiable {
    public let id: String
    public let displayName: String
    public let descriptor: String?

    public init(id: String, displayName: String, descriptor: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.descriptor = descriptor
    }
}

public enum RealtimeVoiceCatalog {
    public static let openAIVoices: [RealtimeVoiceOption] = [
        .init(id: "alloy", displayName: "Alloy", descriptor: "Versatile"),
        .init(id: "echo", displayName: "Echo", descriptor: "Crisp"),
        .init(id: "fable", displayName: "Fable"),
        .init(id: "onyx", displayName: "Onyx"),
        .init(id: "nova", displayName: "Nova"),
        .init(id: "shimmer", displayName: "Shimmer", descriptor: "Gentle"),
        .init(id: "coral", displayName: "Coral", descriptor: "Warm"),
        .init(id: "verse", displayName: "Verse", descriptor: "Dynamic"),
        .init(id: "ballad", displayName: "Ballad", descriptor: "Expressive"),
        .init(id: "ash", displayName: "Ash", descriptor: "Conversational"),
        .init(id: "sage", displayName: "Sage", descriptor: "Authoritative"),
        .init(id: "marin", displayName: "Marin", descriptor: "Natural"),
        .init(id: "cedar", displayName: "Cedar", descriptor: "Friendly"),
    ]

    public static let geminiVoices: [RealtimeVoiceOption] = [
        .init(id: "Zephyr", displayName: "Zephyr", descriptor: "Bright"),
        .init(id: "Puck", displayName: "Puck", descriptor: "Upbeat"),
        .init(id: "Charon", displayName: "Charon", descriptor: "Informative"),
        .init(id: "Kore", displayName: "Kore", descriptor: "Firm"),
        .init(id: "Fenrir", displayName: "Fenrir", descriptor: "Excitable"),
        .init(id: "Leda", displayName: "Leda", descriptor: "Youthful"),
        .init(id: "Orus", displayName: "Orus", descriptor: "Firm"),
        .init(id: "Aoede", displayName: "Aoede", descriptor: "Breezy"),
        .init(id: "Callirrhoe", displayName: "Callirrhoe", descriptor: "Easy-going"),
        .init(id: "Autonoe", displayName: "Autonoe", descriptor: "Bright"),
        .init(id: "Enceladus", displayName: "Enceladus", descriptor: "Breathy"),
        .init(id: "Iapetus", displayName: "Iapetus", descriptor: "Clear"),
        .init(id: "Umbriel", displayName: "Umbriel", descriptor: "Easy-going"),
        .init(id: "Algieba", displayName: "Algieba", descriptor: "Smooth"),
        .init(id: "Despina", displayName: "Despina", descriptor: "Smooth"),
        .init(id: "Erinome", displayName: "Erinome", descriptor: "Clear"),
        .init(id: "Algenib", displayName: "Algenib", descriptor: "Gravelly"),
        .init(id: "Rasalgethi", displayName: "Rasalgethi", descriptor: "Informative"),
        .init(id: "Laomedeia", displayName: "Laomedeia", descriptor: "Upbeat"),
        .init(id: "Achernar", displayName: "Achernar", descriptor: "Soft"),
        .init(id: "Alnilam", displayName: "Alnilam", descriptor: "Firm"),
        .init(id: "Schedar", displayName: "Schedar", descriptor: "Even"),
        .init(id: "Gacrux", displayName: "Gacrux", descriptor: "Mature"),
        .init(id: "Pulcherrima", displayName: "Pulcherrima", descriptor: "Forward"),
        .init(id: "Achird", displayName: "Achird", descriptor: "Friendly"),
        .init(id: "Zubenelgenubi", displayName: "Zubenelgenubi", descriptor: "Casual"),
        .init(id: "Vindemiatrix", displayName: "Vindemiatrix", descriptor: "Gentle"),
        .init(id: "Sadachbia", displayName: "Sadachbia", descriptor: "Lively"),
        .init(id: "Sadaltager", displayName: "Sadaltager", descriptor: "Knowledgeable"),
        .init(id: "Sulafat", displayName: "Sulafat", descriptor: "Warm"),
    ]

    public static let xAIVoices: [RealtimeVoiceOption] = [
        .init(id: "eve", displayName: "Eve", descriptor: "Energetic"),
        .init(id: "ara", displayName: "Ara", descriptor: "Warm"),
        .init(id: "leo", displayName: "Leo", descriptor: "Authoritative"),
        .init(id: "rex", displayName: "Rex", descriptor: "Professional"),
        .init(id: "sal", displayName: "Sal", descriptor: "Balanced"),
    ]

    public static let openAIModels: [RealtimeVoiceModelOption] = [
        .init(id: "gpt-realtime-2", displayName: "gpt-realtime-2", descriptor: "Recommended"),
        .init(id: "gpt-realtime-1.5", displayName: "gpt-realtime-1.5", descriptor: "Previous flagship"),
        .init(id: "gpt-realtime-mini", displayName: "gpt-realtime-mini", descriptor: "Lower latency")
    ]

    public static let geminiModels: [RealtimeVoiceModelOption] = [
        .init(
            id: "gemini-3.1-flash-live-preview",
            displayName: "gemini-3.1-flash-live-preview",
            descriptor: "Recommended"
        ),
        .init(
            id: "gemini-2.5-flash-native-audio-preview-12-2025",
            displayName: "gemini-2.5-flash-native-audio-preview-12-2025",
            descriptor: "Native audio"
        )
    ]

    public static let xAIModels: [RealtimeVoiceModelOption] = [
        .init(
            id: "grok-voice-think-fast-1.0",
            displayName: "grok-voice-think-fast-1.0",
            descriptor: "Recommended"
        ),
        .init(
            id: "grok-voice-fast-1.0",
            displayName: "grok-voice-fast-1.0",
            descriptor: "Legacy"
        )
    ]

    public static func voices(for backend: VoiceProviderBackend) -> [RealtimeVoiceOption] {
        switch backend {
        case .geminiLive:
            return geminiVoices
        case .openAIRealtime:
            return openAIVoices
        case .xAIRealtime:
            return xAIVoices
        }
    }

    public static func models(for backend: VoiceProviderBackend) -> [RealtimeVoiceModelOption] {
        switch backend {
        case .geminiLive:
            return geminiModels
        case .openAIRealtime:
            return openAIModels
        case .xAIRealtime:
            return xAIModels
        }
    }

    public static func defaultVoiceName(for backend: VoiceProviderBackend) -> String {
        switch backend {
        case .geminiLive:
            return "Leda"
        case .openAIRealtime:
            return "marin"
        case .xAIRealtime:
            return "eve"
        }
    }

    public static func defaultModelID(for backend: VoiceProviderBackend) -> String {
        switch backend {
        case .geminiLive:
            return "gemini-3.1-flash-live-preview"
        case .openAIRealtime:
            return "gpt-realtime-2"
        case .xAIRealtime:
            return "grok-voice-think-fast-1.0"
        }
    }
}
