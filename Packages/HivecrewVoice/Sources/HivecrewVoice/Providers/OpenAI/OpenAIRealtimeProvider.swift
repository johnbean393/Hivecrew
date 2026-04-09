//
//  OpenAIRealtimeProvider.swift
//  HivecrewVoice
//
//  Concrete RealtimeVoiceProvider for OpenAI's Realtime API.
//  Follows the same structure as GeminiLiveProvider.
//

import Foundation
import Combine

@MainActor
final class OpenAIRealtimeProvider: NSObject, RealtimeVoiceProvider, ObservableObject {

    // MARK: - Protocol: Observable State

    @Published var connectionState: VoiceConnectionState = .disconnected
    @Published var isModelSpeaking = false
    @Published var totalTokenCount: Int = 0

    // MARK: - Protocol: Sample Rates

    var inputSampleRate: Double { 24000 }
    var outputSampleRate: Double { 24000 }

    // MARK: - Protocol: Callbacks

    var onAudioReceived: (@Sendable (Data) -> Void)?
    var onTranscription: (@Sendable (VoiceTranscription) -> Void)?
    var onToolCall: (@Sendable (VoiceToolCall) -> Void)?
    var onInputActivity: (@Sendable (VoiceInputActivityEvent) -> Void)?
    var onInterrupted: (@Sendable () -> Void)?
    var onTurnComplete: (@Sendable () -> Void)?
    var onError: (@Sendable (Error) -> Void)?
    var onUsageUpdate: (@Sendable (Int) -> Void)?
    var onReconnecting: (@Sendable () -> Void)?
    var onReconnected: (@Sendable () -> Void)?

    // MARK: - Internal State

    var webSocket: URLSessionWebSocketTask?
    var urlSession: URLSession!
    var apiKey: String = ""
    var isReceiving = false

    static let availableModels = ["gpt-realtime-1.5", "gpt-realtime-mini"]
    static let defaultModel = "gpt-realtime-1.5"
    var model: String = "gpt-realtime-1.5"
    var activeModel: String? { model }

    static let availableVoices: [(id: String, name: String, descriptor: String)] = [
        ("marin", "Marin", "Natural"),
        ("cedar", "Cedar", "Friendly"),
        ("alloy", "Alloy", "Versatile"),
        ("ash", "Ash", "Conversational"),
        ("ballad", "Ballad", "Expressive"),
        ("coral", "Coral", "Warm"),
        ("echo", "Echo", "Crisp"),
        ("sage", "Sage", "Authoritative"),
        ("shimmer", "Shimmer", "Gentle"),
        ("verse", "Verse", "Dynamic"),
    ]

    var currentSessionConfig: VoiceSessionConfig?
    var isManualDisconnect = false

    var connectionContinuation: CheckedContinuation<Void, Error>?
    var setupContinuation: CheckedContinuation<Void, Error>?

    var currentOutputTranscript: String = ""
    var hasBufferedInputAudio = false

    // MARK: - Init

    nonisolated override init() {
        super.init()
    }

    func configure(apiKey: String, model: String? = nil) {
        self.apiKey = apiKey
        if let model, OpenAIRealtimeProvider.availableModels.contains(model) {
            self.model = model
        }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        self.urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    // MARK: - Protocol: Send Methods

    func sendAudio(_ pcmData: Data) async throws {
        guard connectionState == .connected, !pcmData.isEmpty else { return }

        let event = InputAudioBufferAppendEvent(audio: pcmData.base64EncodedString())
        do {
            try await sendJSON(event)
            hasBufferedInputAudio = true
        } catch {
            print("Audio send failed: \(error.localizedDescription)")
        }
    }

    func sendAudioStreamEnd() async throws {
        guard connectionState == .connected, hasBufferedInputAudio else { return }
        try await sendJSON(InputAudioBufferCommitEvent())
        hasBufferedInputAudio = false
    }

    func sendVideoFrame(_ jpegData: Data) async throws {
        guard connectionState == .connected, !jpegData.isEmpty else { return }

        let event = ConversationItemCreateEvent(
            item: .init(
                type: "message",
                role: "user",
                content: [
                    .init(
                        type: "input_image",
                        text: nil,
                        imageUrl: "data:image/jpeg;base64,\(jpegData.base64EncodedString())"
                    )
                ],
                callId: nil,
                output: nil
            )
        )
        try await sendJSON(event)
    }

    func sendText(_ text: String) async throws {
        guard connectionState == .connected else { return }

        let itemEvent = ConversationItemCreateEvent(
            item: .init(
                type: "message",
                role: "user",
                content: [.init(type: "input_text", text: text, imageUrl: nil)],
                callId: nil,
                output: nil
            )
        )
        try await sendJSON(itemEvent)
        try await sendJSON(ResponseCreateEvent(response: nil))
    }

    func sendToolResponse(callId: String, name: String, result: String) async throws {
        guard connectionState == .connected else { return }

        let itemEvent = ConversationItemCreateEvent(
            item: .init(
                type: "function_call_output",
                role: nil,
                content: nil,
                callId: callId,
                output: result
            )
        )
        try await sendJSON(itemEvent)
        try await sendJSON(ResponseCreateEvent(response: nil))
    }

    // MARK: - Internal Helpers

    func sendJSON<T: Encodable>(_ message: T) async throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(message)

        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw OpenAIRealtimeError.encodingError
        }

        guard let ws = webSocket else {
            throw OpenAIRealtimeError.notConnected
        }

        try await ws.send(.string(jsonString))
    }
}
