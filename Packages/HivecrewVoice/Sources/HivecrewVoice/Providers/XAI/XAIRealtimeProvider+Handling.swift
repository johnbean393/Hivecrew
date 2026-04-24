//
//  XAIRealtimeProvider+Handling.swift
//  HivecrewVoice
//

import Foundation

extension XAIRealtimeProvider {

    // MARK: - Receive Loop

    func startReceiving() {
        guard !isReceiving else { return }
        isReceiving = true

        Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    func receiveLoop() async {
        while isReceiving, let ws = webSocket {
            do {
                let message = try await ws.receive()
                await handleMessage(message)
            } catch {
                if isReceiving {
                    await MainActor.run {
                        self.isReceiving = false
                        if !self.isManualDisconnect {
                            self.connectionState = .error(error.localizedDescription)
                            self.onError?(error)
                        }
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
            await parseServerEvent(text)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
                await parseServerEvent(text)
            }
        @unknown default:
            break
        }
    }

    func parseServerEvent(_ jsonString: String) async {
        guard let data = jsonString.data(using: .utf8) else { return }

        do {
            let event = try JSONDecoder().decode(OpenAIServerEvent.self, from: data)

            await MainActor.run {
                self.lastTrafficAt = Date()
                switch event.type {

                case "session.created":
                    // Server confirms session is open. Resume connection continuation
                    // if we're still waiting (covers race with delegate callback).
                    if let cont = self.connectionContinuation {
                        self.connectionContinuation = nil
                        cont.resume()
                    }

                case "session.updated":
                    self.connectionState = .connected
                    if let cont = self.setupContinuation {
                        self.setupContinuation = nil
                        cont.resume()
                    }

                case "input_audio_buffer.speech_started":
                    self.onInputActivity?(
                        VoiceInputActivityEvent(kind: .speechStarted, offsetMs: event.audioStartMs)
                    )
                    Task { try? await self.sendJSON(ResponseCancelEvent()) }
                    self.isModelSpeaking = false
                    self.markCurrentOutputTranscriptInterrupted()
                    self.onInterrupted?()

                case "input_audio_buffer.speech_stopped":
                    self.onInputActivity?(
                        VoiceInputActivityEvent(kind: .speechStopped, offsetMs: event.audioEndMs)
                    )

                case "input_audio_buffer.committed":
                    self.hasBufferedInputAudio = false
                    self.awaitingInputTranscriptAfterCommit = true
                    self.onInputActivity?(VoiceInputActivityEvent(kind: .streamCommitted))

                case "response.output_audio.delta":
                    if let base64 = event.delta,
                       let audioData = Data(base64Encoded: base64) {
                        self.isModelSpeaking = true
                        self.onAudioReceived?(audioData)
                    }

                case "response.output_audio_transcript.delta":
                    if let textDelta = event.delta {
                        self.updateOutputTranscript(delta: textDelta, itemId: event.itemId)
                    }

                case "response.output_audio_transcript.done":
                    if let transcript = event.transcript {
                        self.finalizeOutputTranscript(transcript, itemId: event.itemId)
                    }

                case "conversation.item.input_audio_transcription.completed":
                    if let transcript = event.transcript {
                        self.handleCompletedInputTranscript(transcript)
                    }

                case "response.function_call_arguments.done":
                    if let callId = event.callId, let name = event.name {
                        self.emitToolCallIfNeeded(
                            callId: callId,
                            name: name,
                            argumentsJSON: event.arguments
                        )
                    }

                case "response.done":
                    self.handleResponseDone(event)

                case "error":
                    if event.error != nil || event.message != nil {
                        let message = event.error?.message ?? event.message ?? "Unknown error"
                        let error = XAIRealtimeError.sessionSetupFailed(message)
                        self.onError?(error)
                    }

                default:
                    break
                }
            }
        } catch {
            print("Failed to parse xAI server event: \(error)")
        }
    }

    // MARK: - Response Done Handling

    private func handleResponseDone(_ event: OpenAIServerEvent) {
        // Extract function calls
        if let output = event.response?.output {
            for item in output where item.type == "function_call" {
                guard let callId = item.callId, let name = item.name else { continue }
                emitToolCallIfNeeded(
                    callId: callId,
                    name: name,
                    argumentsJSON: item.arguments
                )
            }
        }

        // Extract usage
        if let usage = event.response?.usage, let total = usage.totalTokens {
            self.totalTokenCount += total
            self.onUsageUpdate?(self.totalTokenCount)
        }

        self.isModelSpeaking = false
        self.clearCompletedInterruptedOutputItems(from: event.response?.output)
        self.preserveDeferredOutputTranscriptForTurnCompletion()
        self.onTurnComplete?()
    }

    private func emitToolCallIfNeeded(
        callId: String,
        name: String,
        argumentsJSON: String?
    ) {
        guard deliveredToolCallIDs.insert(callId).inserted else { return }

        var args: [String: String] = [:]
        if let argumentsJSON,
           let argsData = argumentsJSON.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
            for (key, value) in parsed {
                args[key] = "\(value)"
            }
        }

        let toolCall = VoiceToolCall(id: callId, name: name, arguments: args)
        onToolCall?(toolCall)
    }
}
