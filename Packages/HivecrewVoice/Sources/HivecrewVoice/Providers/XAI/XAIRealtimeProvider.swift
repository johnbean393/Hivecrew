//
//  XAIRealtimeProvider.swift
//  HivecrewVoice
//
//  Concrete RealtimeVoiceProvider for xAI's Realtime API.
//  Follows the same structure as GeminiLiveProvider.
//

import Foundation
import Combine

@MainActor
final class XAIRealtimeProvider: NSObject, RealtimeVoiceProvider, ObservableObject {

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
    var onDisconnected: (@Sendable (VoiceDisconnectEvent) -> Void)?
    var onUsageUpdate: (@Sendable (Int) -> Void)?
    var onReconnecting: (@Sendable () -> Void)?
    var onReconnected: (@Sendable () -> Void)?

    // MARK: - Internal State

    var webSocket: URLSessionWebSocketTask?
    var urlSession: URLSession!
    var authentication: VoiceProviderAuthentication = .apiKey("")
    var isReceiving = false
    var lastTrafficAt = Date.distantPast

    static let availableModels = RealtimeVoiceCatalog.xAIModels.map(\.id)
    static let defaultModel = RealtimeVoiceCatalog.defaultModelID(for: .xAIRealtime)
    var model: String = RealtimeVoiceCatalog.defaultModelID(for: .xAIRealtime)
    var activeModel: String? { model }

    static let availableVoices: [(id: String, name: String, descriptor: String)] =
        RealtimeVoiceCatalog.xAIVoices.map { voice in
            (
                id: voice.id,
                name: voice.displayName.capitalized,
                descriptor: voice.descriptor ?? ""
            )
        }

    var currentSessionConfig: VoiceSessionConfig?
    var isManualDisconnect = false

    var connectionContinuation: CheckedContinuation<Void, Error>?
    var setupContinuation: CheckedContinuation<Void, Error>?

    var currentOutputTranscript: String = ""
    var currentOutputTranscriptItemId: String?
    var lastDeliveredOutputTranscript: String = ""
    var deferredOutputTranscript: String?
    var awaitingInputTranscriptAfterCommit = false
    var interruptedOutputTranscriptItemIds = Set<String>()
    var hasBufferedInputAudio = false
    var deliveredToolCallIDs = Set<String>()

    // MARK: - Init

    nonisolated override init() {
        super.init()
    }

    func configure(authentication: VoiceProviderAuthentication, model: String? = nil) {
        self.authentication = authentication
        if let model, XAIRealtimeProvider.availableModels.contains(model) {
            self.model = model
        }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        self.urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func configure(apiKey: String, model: String? = nil) {
        configure(authentication: .apiKey(apiKey), model: model)
    }

    func beginOutputTranscriptStreamIfNeeded(itemId: String?) -> Bool {
        if let itemId, interruptedOutputTranscriptItemIds.contains(itemId) {
            return false
        }

        if let itemId {
            if currentOutputTranscriptItemId != itemId {
                currentOutputTranscript = ""
                lastDeliveredOutputTranscript = ""
                currentOutputTranscriptItemId = itemId
            }
        } else if currentOutputTranscriptItemId == nil {
            lastDeliveredOutputTranscript = ""
        }

        return true
    }

    func updateOutputTranscript(delta: String, itemId: String?) {
        guard beginOutputTranscriptStreamIfNeeded(itemId: itemId) else { return }
        currentOutputTranscript += delta
        queueOrDeliverOutputTranscript(currentOutputTranscript)
    }

    func finalizeOutputTranscript(_ transcript: String, itemId: String?) {
        guard beginOutputTranscriptStreamIfNeeded(itemId: itemId) else { return }
        currentOutputTranscript = transcript
        queueOrDeliverOutputTranscript(transcript)
    }

    func handleCompletedInputTranscript(_ transcript: String) {
        awaitingInputTranscriptAfterCommit = false

        guard !transcript.isEmpty else {
            flushDeferredOutputTranscriptIfNeeded()
            return
        }

        onTranscription?(VoiceTranscription(source: .input, text: transcript))
        flushDeferredOutputTranscriptIfNeeded()
    }

    func queueOrDeliverOutputTranscript(_ transcript: String) {
        guard !transcript.isEmpty else { return }

        if awaitingInputTranscriptAfterCommit {
            deferredOutputTranscript = transcript
            return
        }

        guard transcript != lastDeliveredOutputTranscript else { return }
        lastDeliveredOutputTranscript = transcript
        deferredOutputTranscript = nil
        onTranscription?(VoiceTranscription(source: .output, text: transcript))
    }

    func flushDeferredOutputTranscriptIfNeeded() {
        guard !awaitingInputTranscriptAfterCommit,
              let deferredOutputTranscript,
              !deferredOutputTranscript.isEmpty else {
            return
        }

        self.deferredOutputTranscript = nil
        queueOrDeliverOutputTranscript(deferredOutputTranscript)
    }

    func markCurrentOutputTranscriptInterrupted() {
        if let currentOutputTranscriptItemId {
            interruptedOutputTranscriptItemIds.insert(currentOutputTranscriptItemId)
        }
        resetOutputTranscriptState(clearDeferred: true)
    }

    func preserveDeferredOutputTranscriptForTurnCompletion() {
        if awaitingInputTranscriptAfterCommit,
           deferredOutputTranscript == nil,
           !currentOutputTranscript.isEmpty {
            deferredOutputTranscript = currentOutputTranscript
        }
        resetOutputTranscriptState(clearDeferred: false)
    }

    func resetOutputTranscriptState(clearDeferred: Bool) {
        currentOutputTranscript = ""
        currentOutputTranscriptItemId = nil
        lastDeliveredOutputTranscript = ""
        if clearDeferred {
            deferredOutputTranscript = nil
        }
    }

    func clearCompletedInterruptedOutputItems(from output: [OpenAIServerEvent.OutputItem]?) {
        guard let output else { return }
        for item in output {
            if let id = item.id {
                interruptedOutputTranscriptItemIds.remove(id)
            }
        }
    }

    // MARK: - Protocol: Send Methods

    func sendAudio(_ pcmData: Data) async throws {
        guard !pcmData.isEmpty else { return }
        guard connectionState == .connected else {
            throw XAIRealtimeError.notConnected
        }

        let event = InputAudioBufferAppendEvent(audio: pcmData.base64EncodedString())
        try await sendJSON(event)
        hasBufferedInputAudio = true
    }

    func sendAudioStreamEnd() async throws {
        guard hasBufferedInputAudio else { return }
        guard connectionState == .connected else {
            throw XAIRealtimeError.notConnected
        }
        try await sendJSON(InputAudioBufferCommitEvent())
        hasBufferedInputAudio = false
    }

    func sendVideoFrame(_ jpegData: Data) async throws {
        // xAI Voice Agent currently accepts audio/text turns. Keep video
        // capture optional at the orchestration layer by dropping frames here.
    }

    func sendText(_ text: String) async throws {
        guard connectionState == .connected else {
            throw XAIRealtimeError.notConnected
        }

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
        guard connectionState == .connected else {
            throw XAIRealtimeError.notConnected
        }

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
            throw XAIRealtimeError.encodingError
        }

        guard let ws = webSocket else {
            throw XAIRealtimeError.notConnected
        }

        try await ws.send(.string(jsonString))
        lastTrafficAt = Date()
    }

    func validateConnection() async throws {
        guard connectionState == .connected, let webSocket else {
            throw XAIRealtimeError.notConnected
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            webSocket.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        lastTrafficAt = Date()
    }
}
