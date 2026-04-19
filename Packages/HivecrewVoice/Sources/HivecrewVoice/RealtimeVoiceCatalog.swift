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

public enum RealtimeVoiceCatalog {
    public static let openAIVoices: [RealtimeVoiceOption] = [
        .init(id: "alloy", displayName: "alloy", descriptor: "Versatile"),
        .init(id: "echo", displayName: "echo", descriptor: "Crisp"),
        .init(id: "fable", displayName: "fable"),
        .init(id: "onyx", displayName: "onyx"),
        .init(id: "nova", displayName: "nova"),
        .init(id: "shimmer", displayName: "shimmer", descriptor: "Gentle"),
        .init(id: "coral", displayName: "coral", descriptor: "Warm"),
        .init(id: "verse", displayName: "verse", descriptor: "Dynamic"),
        .init(id: "ballad", displayName: "ballad", descriptor: "Expressive"),
        .init(id: "ash", displayName: "ash", descriptor: "Conversational"),
        .init(id: "sage", displayName: "sage", descriptor: "Authoritative"),
        .init(id: "marin", displayName: "marin", descriptor: "Natural"),
        .init(id: "cedar", displayName: "cedar", descriptor: "Friendly"),
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

    public static func voices(for backend: VoiceProviderBackend) -> [RealtimeVoiceOption] {
        switch backend {
        case .geminiLive:
            return geminiVoices
        case .openAIRealtime:
            return openAIVoices
        }
    }

    public static func defaultVoiceName(for backend: VoiceProviderBackend) -> String {
        switch backend {
        case .geminiLive:
            return "Leda"
        case .openAIRealtime:
            return "marin"
        }
    }
}
