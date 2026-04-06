//
//  RealtimeVoiceProvider.swift
//  HivecrewVoice
//
//  Provider-agnostic protocol for realtime voice backends.
//  Analogous to LLMClientProtocol in HivecrewLLM.
//

import Foundation

@MainActor
public protocol RealtimeVoiceProvider: ObservableObject {

    // MARK: - Connection Lifecycle

    var connectionState: VoiceConnectionState { get }
    func connect(config: VoiceSessionConfig) async throws
    func disconnect()

    // MARK: - Audio Streaming

    /// Expected input sample rate for this provider (e.g. 16000 for Gemini, 24000 for OpenAI).
    var inputSampleRate: Double { get }

    /// Output audio sample rate from this provider.
    var outputSampleRate: Double { get }

    func sendAudio(_ pcmData: Data) async throws
    func sendAudioStreamEnd() async throws

    // MARK: - Video / Image Streaming

    func sendVideoFrame(_ jpegData: Data) async throws

    // MARK: - Text

    func sendText(_ text: String) async throws

    // MARK: - Tool Responses

    func sendToolResponse(callId: String, name: String, result: String) async throws

    // MARK: - Callbacks

    var onAudioReceived: (@Sendable (Data) -> Void)? { get set }
    var onTranscription: (@Sendable (VoiceTranscription) -> Void)? { get set }
    var onToolCall: (@Sendable (VoiceToolCall) -> Void)? { get set }
    var onInterrupted: (@Sendable () -> Void)? { get set }
    var onTurnComplete: (@Sendable () -> Void)? { get set }
    var onError: (@Sendable (Error) -> Void)? { get set }

    /// Fired when the server reports updated token usage for the session.
    var onUsageUpdate: (@Sendable (Int) -> Void)? { get set }

    /// Fired when the server sends a GoAway or the connection drops and
    /// automatic session resumption begins.
    var onReconnecting: (@Sendable () -> Void)? { get set }

    /// Fired after a session resumption reconnect succeeds.
    var onReconnected: (@Sendable () -> Void)? { get set }

    // MARK: - Observable State

    var isModelSpeaking: Bool { get }
    var totalTokenCount: Int { get }
}
