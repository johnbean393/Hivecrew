//
//  VoiceSessionConfig.swift
//  HivecrewVoice
//

import Foundation

public struct VoiceSessionConfig: Sendable {
    public var systemPrompt: String?
    public var voiceName: String?
    public var tools: [VoiceToolDeclaration]
    public var mediaResolution: MediaResolution
    public var thinkingLevel: ThinkingLevel
    public var includeThoughts: Bool
    public var webSearchEnabled: Bool
    public var audioPolicy: AudioPolicy
    public var providerSpecific: [String: String]

    public init(
        systemPrompt: String? = nil,
        voiceName: String? = nil,
        tools: [VoiceToolDeclaration] = [],
        mediaResolution: MediaResolution = .medium,
        thinkingLevel: ThinkingLevel = .low,
        includeThoughts: Bool = true,
        webSearchEnabled: Bool = true,
        audioPolicy: AudioPolicy = .init(),
        providerSpecific: [String: String] = [:]
    ) {
        self.systemPrompt = systemPrompt
        self.voiceName = voiceName
        self.tools = tools
        self.mediaResolution = mediaResolution
        self.thinkingLevel = thinkingLevel
        self.includeThoughts = includeThoughts
        self.webSearchEnabled = webSearchEnabled
        self.audioPolicy = audioPolicy
        self.providerSpecific = providerSpecific
    }

    public enum MediaResolution: String, Sendable, CaseIterable, Identifiable {
        case low = "low"
        case medium = "medium"
        case high = "high"

        public var id: String { rawValue }
    }

    public enum ThinkingLevel: String, Sendable, CaseIterable, Identifiable {
        case minimal = "minimal"
        case low = "low"
        case medium = "medium"
        case high = "high"
        case xhigh = "xhigh"

        public var id: String { rawValue }
    }

    public struct AudioPolicy: Sendable {
        public var preset: Preset
        public var streamEndBehavior: StreamEndBehavior
        public var localSpeakerIsolation: LocalSpeakerIsolation
        public var openAI: OpenAI
        public var gemini: Gemini

        public init(
            preset: Preset = .balanced,
            streamEndBehavior: StreamEndBehavior = .init(),
            localSpeakerIsolation: LocalSpeakerIsolation = .init(),
            openAI: OpenAI = .init(),
            gemini: Gemini = .init()
        ) {
            self.preset = preset
            self.streamEndBehavior = streamEndBehavior
            self.localSpeakerIsolation = localSpeakerIsolation
            self.openAI = openAI
            self.gemini = gemini
        }

        public enum Preset: String, Sendable, CaseIterable, Identifiable {
            case balanced = "balanced"
            case noisyRoom = "noisy_room"

            public var id: String { rawValue }
        }

        public struct StreamEndBehavior: Sendable {
            public var sendOnMute: Bool
            public var sendOnSuspend: Bool
            public var sendOnCallEnd: Bool

            public init(
                sendOnMute: Bool = true,
                sendOnSuspend: Bool = true,
                sendOnCallEnd: Bool = true
            ) {
                self.sendOnMute = sendOnMute
                self.sendOnSuspend = sendOnSuspend
                self.sendOnCallEnd = sendOnCallEnd
            }
        }

        public struct LocalSpeakerIsolation: Sendable, Codable, Equatable {
            public var enabled: Bool
            public var strictMode: Bool
            public var internalSampleRate: Double
            public var analysisWindowMs: Int
            public var decisionStrideMs: Int
            public var outputHoldbackMs: Int
            public var confidenceThresholds: ConfidenceThresholds
            public var profileUpdatePolicy: ProfileUpdatePolicy
            public var extractorKind: ExtractorKind
            public var speechEnhancerKind: SpeechEnhancerKind

            public init(
                enabled: Bool = true,
                strictMode: Bool = true,
                internalSampleRate: Double = 16_000,
                analysisWindowMs: Int = 900,
                decisionStrideMs: Int = 180,
                outputHoldbackMs: Int = 300,
                confidenceThresholds: ConfidenceThresholds = .init(),
                profileUpdatePolicy: ProfileUpdatePolicy = .highConfidenceOnly,
                extractorKind: ExtractorKind = .baselinePassthrough,
                speechEnhancerKind: SpeechEnhancerKind = .hush
            ) {
                self.enabled = enabled
                self.strictMode = strictMode
                self.internalSampleRate = internalSampleRate
                self.analysisWindowMs = analysisWindowMs
                self.decisionStrideMs = decisionStrideMs
                self.outputHoldbackMs = outputHoldbackMs
                self.confidenceThresholds = confidenceThresholds
                self.profileUpdatePolicy = profileUpdatePolicy
                self.extractorKind = extractorKind
                self.speechEnhancerKind = speechEnhancerKind
            }

            public struct ConfidenceThresholds: Sendable, Codable, Equatable {
                /// Maximum cosine distance that still counts as a confident target-speaker match.
                public var pass: Float
                /// Distances between `pass` and `attenuate` are treated as uncertain and attenuated.
                public var attenuate: Float
                /// Distances between `attenuate` and `mute` are treated as non-target speech and muted.
                public var mute: Float

                public init(
                    pass: Float = 0.60,
                    attenuate: Float = 0.70,
                    mute: Float = 0.95
                ) {
                    self.pass = pass
                    self.attenuate = attenuate
                    self.mute = mute
                }
            }

            public enum ProfileUpdatePolicy: String, Sendable, Codable, CaseIterable, Identifiable {
                case off = "off"
                case highConfidenceOnly = "high_confidence_only"

                public var id: String { rawValue }
            }

            public enum ExtractorKind: String, Sendable, Codable, CaseIterable, Identifiable {
                case baselinePassthrough = "baseline_passthrough"
                case voiceFilterLite = "voicefilter_lite"

                public var id: String { rawValue }
            }

            public enum SpeechEnhancerKind: String, Sendable, Codable, CaseIterable, Identifiable {
                case none = "none"
                case hush = "hush"

                public var id: String { rawValue }
            }
        }

        public struct OpenAI: Sendable {
            public var turnDetection: TurnDetection
            public var createResponse: Bool?
            public var interruptResponse: Bool?
            public var noiseReduction: NoiseReduction?

            public init(
                turnDetection: TurnDetection = .semantic(),
                createResponse: Bool? = true,
                interruptResponse: Bool? = true,
                noiseReduction: NoiseReduction? = nil
            ) {
                self.turnDetection = turnDetection
                self.createResponse = createResponse
                self.interruptResponse = interruptResponse
                self.noiseReduction = noiseReduction
            }

            public struct TurnDetection: Sendable {
                public var mode: Mode
                public var threshold: Double?
                public var prefixPaddingMs: Int?
                public var silenceDurationMs: Int?
                public var eagerness: Eagerness?

                public init(
                    mode: Mode,
                    threshold: Double? = nil,
                    prefixPaddingMs: Int? = nil,
                    silenceDurationMs: Int? = nil,
                    eagerness: Eagerness? = nil
                ) {
                    self.mode = mode
                    self.threshold = threshold
                    self.prefixPaddingMs = prefixPaddingMs
                    self.silenceDurationMs = silenceDurationMs
                    self.eagerness = eagerness
                }

                public static func semantic(eagerness: Eagerness? = .auto) -> Self {
                    .init(mode: .semanticVAD, eagerness: eagerness)
                }

                public static func server(
                    threshold: Double? = nil,
                    prefixPaddingMs: Int? = nil,
                    silenceDurationMs: Int? = nil
                ) -> Self {
                    .init(
                        mode: .serverVAD,
                        threshold: threshold,
                        prefixPaddingMs: prefixPaddingMs,
                        silenceDurationMs: silenceDurationMs
                    )
                }

                public enum Mode: String, Sendable {
                    case serverVAD = "server_vad"
                    case semanticVAD = "semantic_vad"
                }

                public enum Eagerness: String, Sendable, CaseIterable, Identifiable {
                    case low
                    case medium
                    case high
                    case auto

                    public var id: String { rawValue }
                }
            }

            public enum NoiseReduction: String, Sendable, CaseIterable, Identifiable {
                case nearField = "near_field"
                case farField = "far_field"

                public var id: String { rawValue }
            }
        }

        public struct Gemini: Sendable {
            public var automaticActivityDetectionEnabled: Bool
            public var startOfSpeechSensitivity: StartSensitivity
            public var endOfSpeechSensitivity: EndSensitivity
            public var prefixPaddingMs: Int?
            public var silenceDurationMs: Int?
            public var activityHandling: ActivityHandling
            public var turnCoverage: TurnCoverage?

            public init(
                automaticActivityDetectionEnabled: Bool = true,
                startOfSpeechSensitivity: StartSensitivity = .high,
                endOfSpeechSensitivity: EndSensitivity = .low,
                prefixPaddingMs: Int? = 100,
                silenceDurationMs: Int? = 500,
                activityHandling: ActivityHandling = .startOfActivityInterrupts,
                turnCoverage: TurnCoverage? = nil
            ) {
                self.automaticActivityDetectionEnabled = automaticActivityDetectionEnabled
                self.startOfSpeechSensitivity = startOfSpeechSensitivity
                self.endOfSpeechSensitivity = endOfSpeechSensitivity
                self.prefixPaddingMs = prefixPaddingMs
                self.silenceDurationMs = silenceDurationMs
                self.activityHandling = activityHandling
                self.turnCoverage = turnCoverage
            }

            public enum StartSensitivity: String, Sendable, CaseIterable, Identifiable {
                case high = "START_SENSITIVITY_HIGH"
                case low = "START_SENSITIVITY_LOW"

                public var id: String { rawValue }
            }

            public enum EndSensitivity: String, Sendable, CaseIterable, Identifiable {
                case high = "END_SENSITIVITY_HIGH"
                case low = "END_SENSITIVITY_LOW"

                public var id: String { rawValue }
            }

            public enum ActivityHandling: String, Sendable, CaseIterable, Identifiable {
                case startOfActivityInterrupts = "START_OF_ACTIVITY_INTERRUPTS"
                case noInterruption = "NO_INTERRUPTION"

                public var id: String { rawValue }
            }

            public enum TurnCoverage: String, Sendable, CaseIterable, Identifiable {
                case onlyActivity = "TURN_INCLUDES_ONLY_ACTIVITY"
                case allInput = "TURN_INCLUDES_ALL_INPUT"
                case audioActivityAndAllVideo = "TURN_INCLUDES_AUDIO_ACTIVITY_AND_ALL_VIDEO"

                public var id: String { rawValue }
            }
        }
    }
}
