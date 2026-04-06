//
//  OpenAIRealtimeProvider+Connection.swift
//  HivecrewVoice
//

import Foundation

extension OpenAIRealtimeProvider {

    // MARK: - Protocol: Connect / Disconnect

    func connect(config: VoiceSessionConfig) async throws {
        guard !apiKey.isEmpty else {
            throw OpenAIRealtimeError.missingAPIKey
        }

        currentSessionConfig = config
        isManualDisconnect = false
        isReceiving = false

        totalTokenCount = 0

        try await establishConnection(config: config)
    }

    func disconnect() {
        isManualDisconnect = true
        isReceiving = false
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        connectionState = .disconnected
        isModelSpeaking = false
        currentOutputTranscript = ""

        connectionContinuation?.resume(throwing: OpenAIRealtimeError.connectionFailed)
        connectionContinuation = nil
        setupContinuation?.resume(throwing: OpenAIRealtimeError.connectionFailed)
        setupContinuation = nil
    }

    // MARK: - Private

    private func establishConnection(config: VoiceSessionConfig) async throws {
        connectionState = .connecting

        let urlString = "wss://api.openai.com/v1/realtime?model=\(model)"

        guard let url = URL(string: urlString) else {
            connectionState = .error("Invalid URL")
            throw OpenAIRealtimeError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

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
                        turnDetection: .init(type: "semantic_vad")
                    ),
                    output: .init(
                        format: .init(type: "audio/pcm", rate: 24000),
                        voice: config.voiceName ?? "marin"
                    )
                ),
                tools: toolDefs,
                toolChoice: toolDefs != nil ? "auto" : nil
            )
        )
    }
}
