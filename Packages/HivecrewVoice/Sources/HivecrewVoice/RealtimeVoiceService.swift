//
//  RealtimeVoiceService.swift
//  HivecrewVoice
//
//  Factory for creating voice providers. Mirrors LLMService in HivecrewLLM.
//

import Foundation

public final class RealtimeVoiceService: Sendable {
    public static let shared = RealtimeVoiceService()

    private init() {}

    @MainActor
    public func createProvider(
        backend: VoiceProviderBackend,
        apiKey: String,
        model: String? = nil
    ) -> any RealtimeVoiceProvider {
        switch backend {
        case .geminiLive:
            let provider = GeminiLiveProvider()
            provider.configure(apiKey: apiKey, model: model)
            return provider
        }
    }
}
