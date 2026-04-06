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
        reconnectTask?.cancel()
        reconnectTask = nil

        try await establishConnection(config: config, resumeHandle: nil, resetUsage: true)
    }

    func disconnect() {
        isManualDisconnect = true
        shouldResumeSession = false
        latestSessionHandle = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        isReceiving = false
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        connectionState = .disconnected
        isModelSpeaking = false
        currentTurnTranscription = ""
        seenAudioFingerprints.removeAll()

        connectionContinuation?.resume(throwing: GeminiError.connectionFailed)
        connectionContinuation = nil
        setupContinuation?.resume(throwing: GeminiError.connectionFailed)
        setupContinuation = nil
    }

    func resumeSessionIfNeeded() {
        guard shouldResumeSession,
              !isManualDisconnect,
              reconnectTask == nil,
              latestSessionHandle != nil,
              let config = currentSessionConfig else { return }

        reconnectTask = Task { [weak self] in
            guard let self else { return }
            defer { self.reconnectTask = nil }

            self.connectionState = .reconnecting
            self.onReconnecting?()

            do {
                try await self.establishConnection(
                    config: config,
                    resumeHandle: self.latestSessionHandle,
                    resetUsage: false
                )
                self.onReconnected?()
            } catch {
                if !self.isManualDisconnect {
                    self.connectionState = .error(error.localizedDescription)
                    self.onError?(error)
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

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.connectionContinuation = continuation

            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if let cont = self.connectionContinuation {
                    self.connectionContinuation = nil
                    cont.resume(throwing: GeminiError.connectionFailed)
                }
            }
        }

        let setupMessage = SetupMessage(setup: buildSessionConfig(config: config, resumeHandle: resumeHandle))

        startReceiving()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.setupContinuation = continuation

            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if let cont = self.setupContinuation {
                    self.setupContinuation = nil
                    cont.resume(throwing: GeminiError.connectionFailed)
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

    private func buildSessionConfig(
        config: VoiceSessionConfig,
        resumeHandle: String?
    ) -> GeminiSessionConfig {
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

        let googleSearch: GeminiSessionConfig.Tool.GoogleSearch? = config.webSearchEnabled
            ? GeminiSessionConfig.Tool.GoogleSearch() : nil

        let tools: [GeminiSessionConfig.Tool]? = {
            if functionDecls == nil && googleSearch == nil { return nil }
            return [GeminiSessionConfig.Tool(googleSearch: googleSearch, functionDeclarations: functionDecls)]
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
                    disabled: false,
                    startOfSpeechSensitivity: "START_SENSITIVITY_HIGH",
                    prefixPaddingMs: 100,
                    endOfSpeechSensitivity: "END_SENSITIVITY_LOW",
                    silenceDurationMs: 500
                ),
                activityHandling: "START_OF_ACTIVITY_INTERRUPTS"
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
