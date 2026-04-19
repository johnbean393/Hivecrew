//
//  GeminiLiveProvider.swift
//  HivecrewVoice
//
//  Concrete RealtimeVoiceProvider for Google Gemini Live.
//  Adapted from Genie's GeminiLiveService.
//

import Foundation
import Combine

@MainActor
final class GeminiLiveProvider: NSObject, RealtimeVoiceProvider, ObservableObject {

    // MARK: - Protocol: Observable State

    @Published var connectionState: VoiceConnectionState = .disconnected
    @Published var isModelSpeaking = false
    @Published var totalTokenCount: Int = 0

    // MARK: - Protocol: Sample Rates

    var inputSampleRate: Double { 16000 }
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
    var apiKey: String = ""
    var isReceiving = false
    var heartbeatTask: Task<Void, Never>?
    var lastTrafficAt = Date.distantPast

    static let availableModels = RealtimeVoiceCatalog.geminiModels.map(\.id)
    static let defaultModel = RealtimeVoiceCatalog.defaultModelID(for: .geminiLive)
    static let maxReconnectAttempts = 2
    static let heartbeatInterval: Duration = .seconds(15)
    var model: String = RealtimeVoiceCatalog.defaultModelID(for: .geminiLive)
    var activeModel: String? { model }
    let apiVersion: String = "v1beta"

    var currentSessionConfig: VoiceSessionConfig?
    var latestSessionHandle: String?
    var shouldResumeSession = false
    var isManualDisconnect = false
    var reconnectTask: Task<Void, Never>?
    var reconnectAttempts = 0

    var connectionContinuation: CheckedContinuation<Void, Error>?
    var setupContinuation: CheckedContinuation<Void, Error>?

    var currentTurnTranscription: String = ""
    var seenAudioFingerprints = Set<Int>()
    var hasActiveInputAudioStream = false

    // MARK: - Init

    nonisolated override init() {
        super.init()
    }

    func configure(apiKey: String, model: String? = nil) {
        self.apiKey = apiKey
        if let model, GeminiLiveProvider.availableModels.contains(model) {
            self.model = model
        }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        self.urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    // MARK: - Protocol: Send Methods

    func sendAudio(_ pcmData: Data) async throws {
        guard !pcmData.isEmpty else { return }
        guard connectionState == .connected else {
            throw GeminiError.notConnected
        }

        let message = RealtimeInputMessage(
            realtimeInput: .init(
                audio: .init(data: pcmData.base64EncodedString(), mimeType: "audio/pcm;rate=16000"),
                video: nil,
                text: nil,
                audioStreamEnd: nil
            )
        )
        try await sendJSON(message)
        hasActiveInputAudioStream = true
    }

    func sendAudioStreamEnd() async throws {
        guard hasActiveInputAudioStream else { return }
        guard connectionState == .connected else {
            throw GeminiError.notConnected
        }

        let message = RealtimeInputMessage(
            realtimeInput: .init(
                audio: nil,
                video: nil,
                text: nil,
                audioStreamEnd: true
            )
        )
        try await sendJSON(message)
        hasActiveInputAudioStream = false
    }

    func sendVideoFrame(_ jpegData: Data) async throws {
        guard !jpegData.isEmpty else { return }
        guard connectionState == .connected else {
            throw GeminiError.notConnected
        }

        let message = RealtimeInputMessage(
            realtimeInput: .init(
                audio: nil,
                video: .init(mimeType: "image/jpeg", data: jpegData.base64EncodedString()),
                text: nil,
                audioStreamEnd: nil
            )
        )
        try await sendJSON(message)
    }

    func sendText(_ text: String) async throws {
        guard connectionState == .connected else {
            throw GeminiError.notConnected
        }

        let message = RealtimeInputMessage(
            realtimeInput: .init(
                audio: nil,
                video: nil,
                text: text,
                audioStreamEnd: nil
            )
        )
        try await sendJSON(message)
    }

    func sendToolResponse(callId: String, name: String, result: String) async throws {
        guard connectionState == .connected else {
            throw GeminiError.notConnected
        }

        let message = ToolResponseMessage(
            toolResponse: .init(
                functionResponses: [
                    .init(id: callId, name: name, response: .init(result: result))
                ]
            )
        )
        try await sendJSON(message)
    }

    // MARK: - Internal Helpers

    func sendJSON<T: Encodable>(_ message: T) async throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(message)

        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw GeminiError.encodingError
        }

        guard let ws = webSocket else {
            throw GeminiError.notConnected
        }

        do {
            try await ws.send(.string(jsonString))
            markTraffic()
        } catch {
            let message = Self.describeSendError(error)
            await processTransportFailure(message: message)
            throw GeminiError.connectionFailed(message)
        }
    }

    func validateConnection() async throws {
        guard connectionState == .connected else {
            throw GeminiError.notConnected
        }
        try await sendPing()
    }

    func audioFingerprint(_ data: Data) -> Int {
        var hasher = Hasher()
        hasher.combine(data.count)
        hasher.combine(data.prefix(32))
        hasher.combine(data.suffix(32))
        return hasher.finalize()
    }

    func isCurrentWebSocketTask(_ task: URLSessionTask) -> Bool {
        guard let webSocket else { return false }
        return webSocket === task
    }

    func markTraffic() {
        lastTrafficAt = Date()
    }

    private nonisolated static func describeSendError(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNetworkConnectionLost:
                return "Network connection lost"
            case NSURLErrorTimedOut:
                return "Connection timed out"
            case NSURLErrorNotConnectedToInternet:
                return "No internet connection"
            default:
                break
            }
        }
        return error.localizedDescription
    }
}
