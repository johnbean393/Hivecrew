//
//  GeminiLiveProvider+Connection.swift
//  HivecrewVoice
//

import Foundation

extension GeminiLiveProvider {

    // MARK: - Protocol: Connect / Disconnect

    func connect(config: VoiceSessionConfig) async throws {
        guard !apiKey.isEmpty else {
            throw GeminiError.missingAPIKey
        }

        currentSessionConfig = config
        latestSessionHandle = nil
        shouldResumeSession = true
        isManualDisconnect = false
        reconnectAttempts = 0
        reconnectTask?.cancel()
        reconnectTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil

        try await establishConnection(config: config, resumeHandle: nil, resetUsage: true)
    }

    func disconnect() {
        isManualDisconnect = true
        shouldResumeSession = false
        latestSessionHandle = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        isReceiving = false
        hasActiveInputAudioStream = false
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        connectionState = .disconnected
        isModelSpeaking = false
        currentTurnTranscription = ""
        seenAudioFingerprints.removeAll()

        connectionContinuation?.resume(throwing: GeminiError.connectionFailed("Disconnected by user"))
        connectionContinuation = nil
        setupContinuation?.resume(throwing: GeminiError.connectionFailed("Disconnected by user"))
        setupContinuation = nil
    }

    func resumeSessionIfNeeded() {
        guard shouldResumeSession,
              !isManualDisconnect,
              reconnectTask == nil,
              let config = currentSessionConfig else { return }

        guard let latestSessionHandle else {
            finishRuntimeDisconnect(message: "Connection to Gemini was lost", recoverable: false)
            return
        }

        guard reconnectAttempts < Self.maxReconnectAttempts else {
            finishRuntimeDisconnect(message: "Gemini session could not be resumed", recoverable: false)
            return
        }

        reconnectTask = Task { [weak self] in
            guard let self else { return }
            defer { self.reconnectTask = nil }

            self.reconnectAttempts += 1
            self.connectionState = .reconnecting
            self.onReconnecting?()

            do {
                try await self.establishConnection(
                    config: config,
                    resumeHandle: latestSessionHandle,
                    resetUsage: false
                )
                self.onReconnected?()
            } catch {
                if self.isManualDisconnect {
                    return
                }

                if self.reconnectAttempts >= Self.maxReconnectAttempts {
                    self.finishRuntimeDisconnect(
                        message: error.localizedDescription,
                        recoverable: false
                    )
                } else {
                    self.resumeSessionIfNeeded()
                }
            }
        }
    }

    /// Proactively close the current WebSocket and reconnect using the
    /// session handle before the server terminates the connection.
    func handleGoAway() {
        guard shouldResumeSession,
              !isManualDisconnect,
              latestSessionHandle != nil else { return }

        isReceiving = false
        heartbeatTask?.cancel()
        heartbeatTask = nil
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        isModelSpeaking = false
        currentTurnTranscription = ""
        seenAudioFingerprints.removeAll()

        resumeSessionIfNeeded()
    }

    // MARK: - Private

    private func establishConnection(
        config: VoiceSessionConfig,
        resumeHandle: String?,
        resetUsage: Bool
    ) async throws {
        connectionState = .connecting
        isManualDisconnect = false
        isReceiving = false
        heartbeatTask?.cancel()
        heartbeatTask = nil

        if resetUsage {
            totalTokenCount = 0
        }

        let urlString = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.\(apiVersion).GenerativeService.BidiGenerateContent?key=\(apiKey)"

        guard let url = URL(string: urlString) else {
            connectionState = .error("Invalid URL")
            throw GeminiError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30

        webSocket = urlSession.webSocketTask(with: request)
        webSocket?.resume()
        markTraffic()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.connectionContinuation = continuation

            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if let cont = self.connectionContinuation {
                    self.connectionContinuation = nil
                    cont.resume(throwing: GeminiError.connectionFailed("Connection timed out"))
                }
            }
        }

        let setupMessage = SetupMessage(setup: buildSessionConfig(config: config, resumeHandle: resumeHandle))

        guard let webSocket else {
            throw GeminiError.notConnected
        }
        startReceiving(for: webSocket)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.setupContinuation = continuation

            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if let cont = self.setupContinuation {
                    self.setupContinuation = nil
                    cont.resume(throwing: GeminiError.connectionFailed("Session setup timed out"))
                }
            }

            Task {
                do {
                    try await self.sendJSON(setupMessage)
                } catch {
                    if let cont = self.setupContinuation {
                        self.setupContinuation = nil
                        cont.resume(throwing: error)
                    }
                }
            }
        }
    }

    func processTransportFailure(message: String) async {
        guard !isManualDisconnect else { return }
        isReceiving = false
        heartbeatTask?.cancel()
        heartbeatTask = nil
        webSocket = nil
        resumeSessionIfNeeded()
        if connectionState != .reconnecting, reconnectTask == nil {
            finishRuntimeDisconnect(message: message, recoverable: false)
        }
    }

    func sendPing() async throws {
        guard let webSocket else {
            throw GeminiError.notConnected
        }
        let currentSocket = webSocket
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            currentSocket.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        markTraffic()
    }

    func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.heartbeatInterval)
                guard !Task.isCancelled else { break }
                guard self.connectionState == .connected,
                      !self.isManualDisconnect else { continue }
                do {
                    try await self.sendPing()
                } catch {
                    await self.processTransportFailure(message: "Gemini heartbeat failed")
                    break
                }
            }
        }
    }

    func finishRuntimeDisconnect(message: String, recoverable: Bool) {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        connectionState = .error(message)
        onDisconnected?(VoiceDisconnectEvent(message: message, recoverable: recoverable))
    }

    func buildSessionConfig(
        config: VoiceSessionConfig,
        resumeHandle: String?
    ) -> GeminiSessionConfig {
        let audioPolicy = config.audioPolicy.gemini
        let functionDecls: [GeminiSessionConfig.Tool.FunctionDeclaration]? = config.tools.isEmpty ? nil :
            config.tools.map { tool in
                GeminiSessionConfig.Tool.FunctionDeclaration(
                    name: tool.name,
                    description: tool.description,
                    parameters: tool.parameters.map { params in
                        GeminiSessionConfig.Tool.FunctionDeclaration.Parameters(
                            type: params.type,
                            properties: params.properties.mapValues { prop in
                                GeminiSessionConfig.Tool.FunctionDeclaration.Parameters.Property(
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

        let tools: [GeminiSessionConfig.Tool]? = {
            guard let functionDecls else { return nil }
            return [GeminiSessionConfig.Tool(googleSearch: nil, functionDeclarations: functionDecls)]
        }()

        let mediaRes: String? = {
            switch config.mediaResolution {
            case .low: return "MEDIA_RESOLUTION_LOW"
            case .medium: return "MEDIA_RESOLUTION_MEDIUM"
            case .high: return "MEDIA_RESOLUTION_HIGH"
            }
        }()

        return GeminiSessionConfig(
            model: "models/\(model)",
            generationConfig: GeminiSessionConfig.GenerationConfig(
                responseModalities: ["AUDIO"],
                speechConfig: GeminiSessionConfig.SpeechConfig(
                    voiceConfig: .init(prebuiltVoiceConfig: .init(voiceName: config.voiceName ?? "Leda"))
                ),
                thinkingConfig: GeminiSessionConfig.ThinkingConfig(
                    thinkingLevel: config.thinkingLevel.rawValue,
                    includeThoughts: config.includeThoughts
                ),
                mediaResolution: mediaRes
            ),
            systemInstruction: config.systemPrompt.map { prompt in
                GeminiSessionConfig.SystemInstruction(parts: [.init(text: prompt)])
            },
            realtimeInputConfig: GeminiSessionConfig.RealtimeInputConfig(
                automaticActivityDetection: .init(
                    disabled: !audioPolicy.automaticActivityDetectionEnabled,
                    startOfSpeechSensitivity: audioPolicy.startOfSpeechSensitivity.rawValue,
                    prefixPaddingMs: audioPolicy.prefixPaddingMs,
                    endOfSpeechSensitivity: audioPolicy.endOfSpeechSensitivity.rawValue,
                    silenceDurationMs: audioPolicy.silenceDurationMs
                ),
                activityHandling: audioPolicy.activityHandling.rawValue,
                turnCoverage: audioPolicy.turnCoverage?.rawValue
            ),
            sessionResumption: GeminiSessionConfig.SessionResumptionConfig(handle: resumeHandle),
            outputAudioTranscription: GeminiSessionConfig.AudioTranscriptionConfig(),
            inputAudioTranscription: GeminiSessionConfig.AudioTranscriptionConfig(),
            tools: tools,
            contextWindowCompression: GeminiSessionConfig.ContextWindowCompressionConfig(
                slidingWindow: .init(),
                triggerTokens: 32768
            )
        )
    }
}
