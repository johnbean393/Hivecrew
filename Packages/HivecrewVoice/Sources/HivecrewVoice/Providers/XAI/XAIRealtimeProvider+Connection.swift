//
//  XAIRealtimeProvider+Connection.swift
//  HivecrewVoice
//

import Foundation

extension XAIRealtimeProvider {

    // MARK: - Protocol: Connect / Disconnect

    func connect(config: VoiceSessionConfig) async throws {
        guard authentication.isConfigured else {
            throw XAIRealtimeError.missingAuthentication
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

        connectionContinuation?.resume(throwing: XAIRealtimeError.connectionFailed)
        connectionContinuation = nil
        setupContinuation?.resume(throwing: XAIRealtimeError.connectionFailed)
        setupContinuation = nil
    }

    // MARK: - Private

    private func establishConnection(config: VoiceSessionConfig) async throws {
        connectionState = .connecting
        let bearerToken = try await authentication.resolveCredential()

        var components = URLComponents()
        components.scheme = "wss"
        components.host = "api.x.ai"
        components.path = "/v1/realtime"
        components.queryItems = [URLQueryItem(name: "model", value: model)]

        guard let url = components.url else {
            connectionState = .error("Invalid URL")
            throw XAIRealtimeError.invalidURL
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
                    cont.resume(throwing: XAIRealtimeError.connectionFailed)
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
                    cont.resume(throwing: XAIRealtimeError.sessionSetupFailed("Timed out"))
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

    func buildSessionUpdate(config: VoiceSessionConfig) -> XAISessionUpdateEvent {
        let audioPolicy = config.audioPolicy.openAI
        let functionToolDefs: [XAISessionUpdateEvent.ToolDefinition] = config.tools.map { tool in
            XAISessionUpdateEvent.ToolDefinition(
                type: "function",
                name: tool.name,
                description: tool.description,
                parameters: tool.parameters.map { params in
                    XAISessionUpdateEvent.ToolParameters(
                        type: params.type,
                        properties: params.properties.mapValues { prop in
                            XAISessionUpdateEvent.ToolProperty(
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

        var toolDefs: [XAISessionUpdateEvent.ToolDefinition] = []
        if config.webSearchEnabled {
            toolDefs.append(.init(type: "web_search", name: nil, description: nil, parameters: nil))
            toolDefs.append(.init(type: "x_search", name: nil, description: nil, parameters: nil))
        }
        toolDefs.append(contentsOf: functionToolDefs)

        return XAISessionUpdateEvent(
            session: .init(
                voice: config.voiceName ?? "eve",
                instructions: config.systemPrompt,
                turnDetection: .init(
                    type: "server_vad",
                    threshold: audioPolicy.turnDetection.threshold,
                    prefixPaddingMs: audioPolicy.turnDetection.prefixPaddingMs,
                    silenceDurationMs: audioPolicy.turnDetection.silenceDurationMs
                ),
                tools: toolDefs.isEmpty ? nil : toolDefs,
                inputAudioTranscription: .init(model: "grok-2-audio"),
                audio: .init(
                    input: .init(
                        format: .init(type: "audio/pcm", rate: 24000)
                    ),
                    output: .init(
                        format: .init(type: "audio/pcm", rate: 24000)
                    )
                )
            )
        )
    }
}
