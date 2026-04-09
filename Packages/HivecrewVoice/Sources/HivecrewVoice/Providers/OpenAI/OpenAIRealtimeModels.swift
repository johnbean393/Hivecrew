//
//  OpenAIRealtimeModels.swift
//  HivecrewVoice
//
//  OpenAI Realtime API Codable types. Internal to the package.
//

import Foundation

// MARK: - Client Events (Encodable)

struct SessionUpdateEvent: Encodable {
    let type = "session.update"
    let session: SessionConfig

    struct SessionConfig: Encodable {
        let type: String
        let model: String?
        let instructions: String?
        let outputModalities: [String]?
        let audio: AudioConfig?
        let tools: [ToolDefinition]?
        let toolChoice: String?

        enum CodingKeys: String, CodingKey {
            case type, model, instructions
            case outputModalities = "output_modalities"
            case audio, tools
            case toolChoice = "tool_choice"
        }
    }

    struct AudioConfig: Encodable {
        let input: AudioInputConfig?
        let output: AudioOutputConfig?
    }

    struct AudioInputConfig: Encodable {
        let format: AudioFormat?
        let transcription: InputAudioTranscription?
        let noiseReduction: NoiseReduction?
        let turnDetection: TurnDetection?

        enum CodingKeys: String, CodingKey {
            case format, transcription
            case noiseReduction = "noise_reduction"
            case turnDetection = "turn_detection"
        }
    }

    struct InputAudioTranscription: Encodable {
        let model: String
    }

    struct AudioOutputConfig: Encodable {
        let format: AudioFormat?
        let voice: String?
    }

    struct AudioFormat: Encodable {
        let type: String
        let rate: Int?
    }

    struct TurnDetection: Encodable {
        let type: String
        let threshold: Double?
        let prefixPaddingMs: Int?
        let silenceDurationMs: Int?
        let eagerness: String?
        let createResponse: Bool?
        let interruptResponse: Bool?

        enum CodingKeys: String, CodingKey {
            case type, threshold, eagerness
            case prefixPaddingMs = "prefix_padding_ms"
            case silenceDurationMs = "silence_duration_ms"
            case createResponse = "create_response"
            case interruptResponse = "interrupt_response"
        }
    }

    struct NoiseReduction: Encodable {
        let type: String
    }

    struct ToolDefinition: Encodable {
        let type: String
        let name: String
        let description: String
        let parameters: ToolParameters?
    }

    struct ToolParameters: Encodable {
        let type: String
        let properties: [String: ToolProperty]
        let required: [String]?
    }

    struct ToolProperty: Encodable {
        let type: String
        let description: String
        let `enum`: [String]?
    }
}

struct InputAudioBufferAppendEvent: Encodable {
    let type = "input_audio_buffer.append"
    let audio: String
}

struct InputAudioBufferCommitEvent: Encodable {
    let type = "input_audio_buffer.commit"
}

struct InputAudioBufferClearEvent: Encodable {
    let type = "input_audio_buffer.clear"
}

struct ConversationItemCreateEvent: Encodable {
    let type = "conversation.item.create"
    let item: ConversationItem

    struct ConversationItem: Encodable {
        let type: String
        let role: String?
        let content: [ContentPart]?
        let callId: String?
        let output: String?

        enum CodingKeys: String, CodingKey {
            case type, role, content
            case callId = "call_id"
            case output
        }
    }

    struct ContentPart: Encodable {
        let type: String
        let text: String?
        let imageUrl: String?

        enum CodingKeys: String, CodingKey {
            case type, text
            case imageUrl = "image_url"
        }
    }
}

struct ResponseCreateEvent: Encodable {
    let type = "response.create"
    let response: ResponseConfig?

    struct ResponseConfig: Encodable {
        let outputModalities: [String]?
        let instructions: String?

        enum CodingKeys: String, CodingKey {
            case outputModalities = "output_modalities"
            case instructions
        }
    }
}

struct ResponseCancelEvent: Encodable {
    let type = "response.cancel"
}

// MARK: - Server Events (Decodable)

struct OpenAIServerEvent: Decodable {
    let type: String
    let eventId: String?

    let session: SessionInfo?

    // Audio / transcript deltas (shared field name across multiple event types)
    let delta: String?
    let responseId: String?
    let itemId: String?
    let outputIndex: Int?
    let contentIndex: Int?

    // response.done payload
    let response: ResponseInfo?

    // input_audio_buffer timing
    let audioStartMs: Int?
    let audioEndMs: Int?

    // Transcription completion
    let transcript: String?

    // response.function_call_arguments.done fields
    let name: String?
    let callId: String?
    let arguments: String?

    // Error
    let error: ErrorInfo?

    enum CodingKeys: String, CodingKey {
        case type
        case eventId = "event_id"
        case session, delta
        case responseId = "response_id"
        case itemId = "item_id"
        case outputIndex = "output_index"
        case contentIndex = "content_index"
        case response
        case audioStartMs = "audio_start_ms"
        case audioEndMs = "audio_end_ms"
        case transcript
        case name
        case callId = "call_id"
        case arguments
        case error
    }

    struct SessionInfo: Decodable {
        let id: String?
        let model: String?
        let voice: String?
    }

    struct ResponseInfo: Decodable {
        let id: String?
        let status: String?
        let output: [OutputItem]?
        let usage: UsageInfo?
    }

    struct OutputItem: Decodable {
        let type: String?
        let id: String?
        let name: String?
        let callId: String?
        let arguments: String?
        let status: String?

        enum CodingKeys: String, CodingKey {
            case type, id, name
            case callId = "call_id"
            case arguments, status
        }
    }

    struct UsageInfo: Decodable {
        let totalTokens: Int?
        let inputTokens: Int?
        let outputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case totalTokens = "total_tokens"
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }

    struct ErrorInfo: Decodable {
        let type: String?
        let code: String?
        let message: String?
    }
}

// MARK: - Errors

enum OpenAIRealtimeError: LocalizedError {
    case missingAPIKey
    case invalidURL
    case encodingError
    case connectionFailed
    case notConnected
    case sessionSetupFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "API key is required"
        case .invalidURL: return "Invalid WebSocket URL"
        case .encodingError: return "Failed to encode message"
        case .connectionFailed: return "Failed to connect to OpenAI Realtime"
        case .notConnected: return "Not connected to OpenAI Realtime"
        case .sessionSetupFailed(let msg): return "Session setup failed: \(msg)"
        }
    }
}
