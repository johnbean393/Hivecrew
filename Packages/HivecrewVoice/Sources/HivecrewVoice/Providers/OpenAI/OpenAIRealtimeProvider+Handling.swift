//
//  OpenAIRealtimeProvider+Handling.swift
//  HivecrewVoice
//

import Foundation

extension OpenAIRealtimeProvider {

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
                    self.isModelSpeaking = false
                    self.currentOutputTranscript = ""
                    self.onInterrupted?()

                case "input_audio_buffer.speech_stopped":
                    self.onInputActivity?(
                        VoiceInputActivityEvent(kind: .speechStopped, offsetMs: event.audioEndMs)
                    )

                case "input_audio_buffer.committed":
                    self.hasBufferedInputAudio = false
                    self.onInputActivity?(VoiceInputActivityEvent(kind: .streamCommitted))

                case "response.output_audio.delta":
                    if let base64 = event.delta,
                       let audioData = Data(base64Encoded: base64) {
                        self.isModelSpeaking = true
                        self.onAudioReceived?(audioData)
                    }

                case "response.output_audio_transcript.delta":
                    if let textDelta = event.delta {
                        self.currentOutputTranscript += textDelta
                        self.onTranscription?(
                            VoiceTranscription(source: .output, text: self.currentOutputTranscript)
                        )
                    }

                case "response.output_audio_transcript.done":
                    if let transcript = event.transcript {
                        self.onTranscription?(
                            VoiceTranscription(source: .output, text: transcript)
                        )
                    }

                case "conversation.item.input_audio_transcription.completed":
                    if let transcript = event.transcript {
                        self.onTranscription?(
                            VoiceTranscription(source: .input, text: transcript)
                        )
                    }

                case "response.done":
                    self.handleResponseDone(event)

                case "error":
                    if let errorInfo = event.error {
                        let message = errorInfo.message ?? "Unknown error"
                        let error = OpenAIRealtimeError.sessionSetupFailed(message)
                        self.onError?(error)
                    }

                default:
                    break
                }
            }
        } catch {
            print("Failed to parse OpenAI server event: \(error)")
        }
    }

    // MARK: - Response Done Handling

    private func handleResponseDone(_ event: OpenAIServerEvent) {
        // Extract function calls
        if let output = event.response?.output {
            for item in output where item.type == "function_call" {
                guard let callId = item.callId, let name = item.name else { continue }

                var args: [String: String] = [:]
                if let argsJSON = item.arguments,
                   let argsData = argsJSON.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
                    for (key, value) in parsed {
                        args[key] = "\(value)"
                    }
                }

                let toolCall = VoiceToolCall(id: callId, name: name, arguments: args)
                self.onToolCall?(toolCall)
            }
        }

        // Extract usage
        if let usage = event.response?.usage, let total = usage.totalTokens {
            self.totalTokenCount += total
            self.onUsageUpdate?(self.totalTokenCount)
        }

        self.isModelSpeaking = false
        self.currentOutputTranscript = ""
        self.onTurnComplete?()
    }
}
