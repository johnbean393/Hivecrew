//
//  OpenAIRealtimeProvider+Connection.swift
//  HivecrewVoice
//

import Foundation

extension OpenAIRealtimeProvider {

    // MARK: - Protocol: Connect / Disconnect

    func connect(config: VoiceSessionConfig) async throws {
        guard authentication.isConfigured else {
            throw OpenAIRealtimeError.missingAuthentication
        }

        currentSessionConfig = config
        isManualDisconnect = false
        isReceiving = false
        deliveredToolCallIDs.removeAll()
        awaitingInputTranscriptAfterCommit = false
        interruptedOutputTranscriptItemIds.removeAll()
        resetOutputTranscriptState(clearDeferred: true)

        totalTokenCount = 0

        try await establishConnection(config: config)
    }

    func disconnect() {
        isManualDisconnect = true
        isReceiving = false
        hasBufferedInputAudio = false
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        connectionState = .disconnected
        isModelSpeaking = false
        awaitingInputTranscriptAfterCommit = false
        interruptedOutputTranscriptItemIds.removeAll()
        resetOutputTranscriptState(clearDeferred: true)
        deliveredToolCallIDs.removeAll()

        connectionContinuation?.resume(throwing: OpenAIRealtimeError.connectionFailed)
        connectionContinuation = nil
        setupContinuation?.resume(throwing: OpenAIRealtimeError.connectionFailed)
        setupContinuation = nil
    }

    // MARK: - Private

    private func establishConnection(config: VoiceSessionConfig) async throws {
        connectionState = .connecting
        let bearerToken = try await authentication.resolveCredential()

        let urlString = "wss://api.openai.com/v1/realtime?model=\(model)"

        guard let url = URL(string: urlString) else {
            connectionState = .error("Invalid URL")
            throw OpenAIRealtimeError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")

        webSocket = urlSession.webSocketTask(with: request)
        webSocket?.resume()

        // Wait for WebSocket open
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.connectionContinuation = continuation

            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if let cont = self.connectionContinuation {
                    self.connectionContinuation = nil
                    cont.resume(throwing: OpenAIRealtimeError.connectionFailed)
                }
            }
        }

        startReceiving()

        // Send session.update with our configuration
        let sessionUpdate = buildSessionUpdate(config: config)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.setupContinuation = continuation

            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if let cont = self.setupContinuation {
                    self.setupContinuation = nil
                    cont.resume(throwing: OpenAIRealtimeError.sessionSetupFailed("Timed out"))
                }
            }

            Task {
                do {
                    try await self.sendJSON(sessionUpdate)
                } catch {
                    if let cont = self.setupContinuation {
                        self.setupContinuation = nil
                        cont.resume(throwing: error)
                    }
                }
            }
        }
    }

    func buildSessionUpdate(config: VoiceSessionConfig) -> SessionUpdateEvent {
        let audioPolicy = config.audioPolicy.openAI
        let toolDefs: [SessionUpdateEvent.ToolDefinition]? = config.tools.isEmpty ? nil :
            config.tools.map { tool in
                SessionUpdateEvent.ToolDefinition(
                    type: "function",
                    name: tool.name,
                    description: tool.description,
                    parameters: tool.parameters.map { params in
                        SessionUpdateEvent.ToolParameters(
                            type: params.type,
                            properties: params.properties.mapValues { prop in
                                SessionUpdateEvent.ToolProperty(
                                    type: prop.type,
                                    description: prop.description,
                                    enum: prop.enumValues
                                )
                            },
                            required: params.required
                        )
                    }
                )
            }

        return SessionUpdateEvent(
            session: .init(
                type: "realtime",
                model: model,
                instructions: config.systemPrompt,
                outputModalities: ["audio"],
                audio: .init(
                    input: .init(
                        format: .init(type: "audio/pcm", rate: 24000),
                        transcription: .init(model: "gpt-4o-mini-transcribe"),
                        noiseReduction: audioPolicy.noiseReduction.map {
                            SessionUpdateEvent.NoiseReduction(type: $0.rawValue)
                        },
                        turnDetection: .init(
                            type: audioPolicy.turnDetection.mode.rawValue,
                            threshold: audioPolicy.turnDetection.threshold,
                            prefixPaddingMs: audioPolicy.turnDetection.prefixPaddingMs,
                            silenceDurationMs: audioPolicy.turnDetection.silenceDurationMs,
                            eagerness: audioPolicy.turnDetection.eagerness?.rawValue,
                            createResponse: audioPolicy.createResponse,
                            interruptResponse: audioPolicy.interruptResponse
                        )
                    ),
                    output: .init(
                        format: .init(type: "audio/pcm", rate: 24000),
                        voice: config.voiceName ?? "marin"
                    )
                ),
                tools: toolDefs,
                toolChoice: toolDefs != nil ? "auto" : nil,
                reasoning: reasoningConfig(for: model, config: config)
            )
        )
    }

    private func reasoningConfig(
        for model: String,
        config: VoiceSessionConfig
    ) -> SessionUpdateEvent.ReasoningConfig? {
        guard model.lowercased().hasPrefix("gpt-realtime-2") else {
            return nil
        }

        let effort = switch config.thinkingLevel {
        case .minimal:
            "low"
        case .low, .medium, .high:
            config.thinkingLevel.rawValue
        }

        return SessionUpdateEvent.ReasoningConfig(effort: effort)
    }
}
