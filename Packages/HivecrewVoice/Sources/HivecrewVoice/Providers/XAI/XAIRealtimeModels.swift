//
//  XAIRealtimeModels.swift
//  HivecrewVoice
//
//  xAI Voice Agent API Codable types. Internal to the package.
//

import Foundation

struct XAISessionUpdateEvent: Encodable {
    let type = "session.update"
    let session: SessionConfig

    struct SessionConfig: Encodable {
        let voice: String?
        let instructions: String?
        let turnDetection: TurnDetection?
        let tools: [ToolDefinition]?
        let inputAudioTranscription: InputAudioTranscription?
        let audio: AudioConfig?

        enum CodingKeys: String, CodingKey {
            case voice, instructions
            case turnDetection = "turn_detection"
            case tools
            case inputAudioTranscription = "input_audio_transcription"
            case audio
        }
    }

    struct TurnDetection: Encodable {
        let type: String
        let threshold: Double?
        let prefixPaddingMs: Int?
        let silenceDurationMs: Int?

        enum CodingKeys: String, CodingKey {
            case type, threshold
            case prefixPaddingMs = "prefix_padding_ms"
            case silenceDurationMs = "silence_duration_ms"
        }
    }

    struct InputAudioTranscription: Encodable {
        let model: String
    }

    struct AudioConfig: Encodable {
        let input: AudioEndpointConfig?
        let output: AudioEndpointConfig?
    }

    struct AudioEndpointConfig: Encodable {
        let format: AudioFormat?
    }

    struct AudioFormat: Encodable {
        let type: String
        let rate: Int?
    }

    struct ToolDefinition: Encodable {
        let type: String
        let name: String?
        let description: String?
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

enum XAIRealtimeError: LocalizedError {
    case missingAuthentication
    case invalidURL
    case encodingError
    case connectionFailed
    case notConnected
    case sessionSetupFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAuthentication: return "Authentication is required"
        case .invalidURL: return "Invalid WebSocket URL"
        case .encodingError: return "Failed to encode message"
        case .connectionFailed: return "Failed to connect to xAI Realtime"
        case .notConnected: return "Not connected to xAI Realtime"
        case .sessionSetupFailed(let msg): return "Session setup failed: \(msg)"
        }
    }
}
