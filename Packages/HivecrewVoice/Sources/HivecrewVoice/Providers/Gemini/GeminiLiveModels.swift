//
//  GeminiLiveModels.swift
//  HivecrewVoice
//
//  Gemini Live API Codable types. Internal to the package.
//

import Foundation

// MARK: - Session Configuration

struct GeminiSessionConfig: Encodable {
    let model: String
    let generationConfig: GenerationConfig
    let systemInstruction: SystemInstruction?
    let realtimeInputConfig: RealtimeInputConfig?
    let sessionResumption: SessionResumptionConfig?
    let outputAudioTranscription: AudioTranscriptionConfig?
    let inputAudioTranscription: AudioTranscriptionConfig?
    let tools: [Tool]?
    let contextWindowCompression: ContextWindowCompressionConfig?

    struct GenerationConfig: Encodable {
        let responseModalities: [String]
        let speechConfig: SpeechConfig?
        let thinkingConfig: ThinkingConfig?
        let mediaResolution: String?
    }

    struct ThinkingConfig: Encodable {
        let thinkingLevel: String
        let includeThoughts: Bool?
    }

    struct SpeechConfig: Encodable {
        let voiceConfig: VoiceConfig

        struct VoiceConfig: Encodable {
            let prebuiltVoiceConfig: PrebuiltVoiceConfig

            struct PrebuiltVoiceConfig: Encodable {
                let voiceName: String
            }
        }
    }

    struct SystemInstruction: Encodable {
        let parts: [Part]

        struct Part: Encodable {
            let text: String
        }
    }

    struct RealtimeInputConfig: Encodable {
        let automaticActivityDetection: AutomaticActivityDetection?
        let activityHandling: String?
        let turnCoverage: String?

        struct AutomaticActivityDetection: Encodable {
            let disabled: Bool?
            let startOfSpeechSensitivity: String?
            let prefixPaddingMs: Int?
            let endOfSpeechSensitivity: String?
            let silenceDurationMs: Int?
        }
    }

    struct SessionResumptionConfig: Encodable {
        let handle: String?
    }

    struct AudioTranscriptionConfig: Encodable {}

    struct Tool: Encodable {
        let googleSearch: GoogleSearch?
        let functionDeclarations: [FunctionDeclaration]?

        struct GoogleSearch: Encodable {}

        struct FunctionDeclaration: Encodable {
            let name: String
            let description: String
            let parameters: Parameters?

            struct Parameters: Encodable {
                let type: String
                let properties: [String: Property]
                let required: [String]?

                struct Property: Encodable {
                    let type: String
                    let description: String
                    let `enum`: [String]?
                }
            }
        }
    }

    struct ContextWindowCompressionConfig: Encodable {
        let slidingWindow: SlidingWindow
        let triggerTokens: Int?

        struct SlidingWindow: Encodable {}
    }
}

// MARK: - Client Messages

struct SetupMessage: Encodable {
    let setup: GeminiSessionConfig
}

struct RealtimeInputMessage: Encodable {
    let realtimeInput: RealtimeInput

    struct RealtimeInput: Encodable {
        let audio: AudioBlob?
        let video: VideoBlob?
        let text: String?
        let audioStreamEnd: Bool?

        struct AudioBlob: Encodable {
            let data: String
            let mimeType: String
        }

        struct VideoBlob: Encodable {
            let mimeType: String
            let data: String
        }
    }
}

struct ClientContentMessage: Encodable {
    let clientContent: ClientContent

    struct ClientContent: Encodable {
        let turns: [Turn]
        let turnComplete: Bool

        struct Turn: Encodable {
            let role: String
            let parts: [Part]

            struct Part: Encodable {
                let text: String?
            }
        }
    }
}

struct ToolResponseMessage: Encodable {
    let toolResponse: ToolResponse

    struct ToolResponse: Encodable {
        let functionResponses: [FunctionResponse]

        struct FunctionResponse: Encodable {
            let id: String
            let name: String
            let response: Response

            struct Response: Encodable {
                let result: String
            }
        }
    }
}

// MARK: - Server Messages

struct ServerMessage: Decodable {
    let setupComplete: SetupComplete?
    let serverContent: ServerContent?
    let toolCall: ToolCall?
    let toolCallCancellation: ToolCallCancellation?
    let goAway: GoAway?
    let sessionResumptionUpdate: SessionResumptionUpdate?
    let usageMetadata: UsageMetadata?

    struct SetupComplete: Decodable {}

    struct ServerContent: Decodable {
        let modelTurn: ModelTurn?
        let turnComplete: Bool?
        let interrupted: Bool?
        let generationComplete: Bool?
        let inputTranscription: Transcription?
        let outputTranscription: Transcription?

        struct ModelTurn: Decodable {
            let parts: [Part]?

            struct Part: Decodable {
                let text: String?
                let inlineData: InlineData?
                let thought: Bool?

                struct InlineData: Decodable {
                    let mimeType: String?
                    let data: String?
                }
            }
        }

        struct Transcription: Decodable {
            let text: String?
        }
    }

    struct ToolCall: Decodable {
        let functionCalls: [FunctionCall]?

        struct FunctionCall: Decodable {
            let id: String?
            let name: String?
            let args: [String: String]?
        }
    }

    struct ToolCallCancellation: Decodable {
        let ids: [String]?
    }

    struct GoAway: Decodable {
        let timeLeft: String?
    }

    struct SessionResumptionUpdate: Decodable {
        let newHandle: String?
        let resumable: Bool?
    }

    struct UsageMetadata: Decodable {
        let totalTokenCount: Int?
        let promptTokenCount: Int?
        let responseTokenCount: Int?
    }
}

// MARK: - Errors

enum GeminiError: LocalizedError {
    case missingAPIKey
    case invalidURL
    case encodingError
    case connectionFailed(String)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "API key is required"
        case .invalidURL: return "Invalid WebSocket URL"
        case .encodingError: return "Failed to encode message"
        case .connectionFailed(let reason): return "Gemini: \(reason)"
        case .notConnected: return "Not connected to Gemini"
        }
    }
}
