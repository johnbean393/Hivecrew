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
        authentication: VoiceProviderAuthentication,
        model: String? = nil,
        proxyBaseURL: String? = nil,
        proxyToken: String? = nil
    ) -> any RealtimeVoiceProvider {
        switch backend {
        case .geminiLive:
            let provider = GeminiLiveProvider()
            provider.configure(apiKey: authentication.apiKey ?? "", model: model)
            return provider
        case .openAIRealtime:
            let provider = OpenAIRealtimeProvider()
            provider.configure(
                authentication: authentication,
                model: model,
                proxyBaseURL: proxyBaseURL,
                proxyToken: proxyToken
            )
            return provider
        case .xAIRealtime:
            let provider = XAIRealtimeProvider()
            provider.configure(authentication: authentication, model: model)
            return provider
        }
    }

    @MainActor
    public func createProvider(
        backend: VoiceProviderBackend,
        apiKey: String,
        model: String? = nil
    ) -> any RealtimeVoiceProvider {
        createProvider(
            backend: backend,
            authentication: .apiKey(apiKey),
            model: model
        )
    }
}
