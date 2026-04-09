//
//  GeminiLiveProvider+Handling.swift
//  HivecrewVoice
//

import Foundation

extension GeminiLiveProvider {

    // MARK: - Receive Loop

    func startReceiving(for webSocketTask: URLSessionWebSocketTask) {
        guard !isReceiving, isCurrentWebSocketTask(webSocketTask) else { return }
        isReceiving = true

        Task { [weak self, weak webSocketTask] in
            guard let self, let webSocketTask else { return }
            await self.receiveLoop(for: webSocketTask)
        }
    }

    func receiveLoop(for webSocketTask: URLSessionWebSocketTask) async {
        while isReceiving, isCurrentWebSocketTask(webSocketTask) {
            do {
                let message = try await webSocketTask.receive()
                guard isCurrentWebSocketTask(webSocketTask) else { break }
                await handleMessage(message)
            } catch {
                if isReceiving {
                    await MainActor.run {
                        guard self.isCurrentWebSocketTask(webSocketTask) else { return }
                        self.isReceiving = false
                        self.resumeSessionIfNeeded()
                    }
                }
                break
            }
        }
    }

    // MARK: - Message Dispatch

    func handleMessage(_ message: URLSessionWebSocketTask.Message) async {
        switch message {
        case .string(let text):
            await parseServerMessage(text)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
                await parseServerMessage(text)
            }
        @unknown default:
            break
        }
    }

    func parseServerMessage(_ jsonString: String) async {
        guard let data = jsonString.data(using: .utf8) else { return }

        do {
            let serverMessage = try JSONDecoder().decode(ServerMessage.self, from: data)

            await MainActor.run {
                // Setup complete
                if serverMessage.setupComplete != nil {
                    self.connectionState = .connected
                    self.shouldResumeSession = true
                    if let cont = self.setupContinuation {
                        self.setupContinuation = nil
                        cont.resume()
                    }
                }

                // Server content
                if let content = serverMessage.serverContent {
                    self.handleServerContent(content)
                }

                // Session resumption
                if let update = serverMessage.sessionResumptionUpdate,
                   update.resumable == true,
                   let handle = update.newHandle, !handle.isEmpty {
                    self.latestSessionHandle = handle
                }

                // GoAway — proactively reconnect before server kills us
                if serverMessage.goAway != nil {
                    self.handleGoAway()
                }

                // Usage
                if let usage = serverMessage.usageMetadata,
                   let total = usage.totalTokenCount {
                    self.totalTokenCount += total
                    self.onUsageUpdate?(self.totalTokenCount)
                }

                // Tool calls -- normalized to protocol type
                if let toolCall = serverMessage.toolCall,
                   let functionCalls = toolCall.functionCalls {
                    for fc in functionCalls {
                        guard let id = fc.id, let name = fc.name else { continue }
                        let normalized = VoiceToolCall(
                            id: id,
                            name: name,
                            arguments: fc.args ?? [:]
                        )
                        self.onToolCall?(normalized)
                    }
                }
            }
        } catch {
            print("Failed to parse server message: \(error)")
        }
    }

    // MARK: - Content Handling

    private func handleServerContent(_ content: ServerMessage.ServerContent) {
        // Audio
        if let modelTurn = content.modelTurn, let parts = modelTurn.parts {
            for part in parts {
                if let inlineData = part.inlineData,
                   let base64 = inlineData.data,
                   let audioData = Data(base64Encoded: base64) {
                    let fp = audioFingerprint(audioData)
                    if seenAudioFingerprints.insert(fp).inserted {
                        isModelSpeaking = true
                        onAudioReceived?(audioData)
                    }
                }
            }
        }

        // Interruption
        if content.interrupted == true {
            print("[VoiceMetrics][Gemini] server interrupted current turn")
            isModelSpeaking = false
            onInterrupted?()
            currentTurnTranscription = ""
            seenAudioFingerprints.removeAll()
        }

        // Turn complete
        if content.turnComplete == true {
            print("[VoiceMetrics][Gemini] server turn completed")
            isModelSpeaking = false
            onTurnComplete?()
            currentTurnTranscription = ""
            seenAudioFingerprints.removeAll()
        }

        // Transcriptions
        if let text = content.outputTranscription?.text {
            currentTurnTranscription += text
            onTranscription?(VoiceTranscription(source: .output, text: currentTurnTranscription))
        }
        if let text = content.inputTranscription?.text {
            onTranscription?(VoiceTranscription(source: .input, text: text))
        }
    }
}
