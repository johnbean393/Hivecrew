import Foundation

public struct SpeakerIsolationProfile: Codable, Sendable, Equatable {
    public var id: String
    public var displayName: String
    public var embedding: [Float]
    public var enrolledAt: Date
    public var modelIdentifier: String
    public var sampleRate: Double
    public var sampleCount: Int

    public init(
        id: String,
        displayName: String = "Primary User",
        embedding: [Float],
        enrolledAt: Date = .now,
        modelIdentifier: String,
        sampleRate: Double,
        sampleCount: Int
    ) {
        self.id = id
        self.displayName = displayName
        self.embedding = embedding
        self.enrolledAt = enrolledAt
        self.modelIdentifier = modelIdentifier
        self.sampleRate = sampleRate
        self.sampleCount = sampleCount
    }
}

public enum SpeakerIsolationGate: String, Codable, Sendable, Equatable {
    case pass
    case attenuate
    case mute
}

public struct SpeakerIsolationDecision: Codable, Sendable, Equatable {
    public var gate: SpeakerIsolationGate
    public var distance: Float?
    public var updatedAt: Date
    public var analysisPower: Float
    public var usedHoldback: Bool

    public init(
        gate: SpeakerIsolationGate,
        distance: Float?,
        updatedAt: Date = .now,
        analysisPower: Float = 0,
        usedHoldback: Bool = false
    ) {
        self.gate = gate
        self.distance = distance
        self.updatedAt = updatedAt
        self.analysisPower = analysisPower
        self.usedHoldback = usedHoldback
    }
}

public struct SpeakerIsolationEngineMetrics: Sendable, Equatable {
    public var decisionCount: Int = 0
    public var passCount: Int = 0
    public var attenuateCount: Int = 0
    public var muteCount: Int = 0
    public var averageDistance: Float = 0
    public var lastDecision: SpeakerIsolationDecision = .init(gate: .mute, distance: nil)

    public init() {}
}

public struct VoiceSessionCaptureMetadata: Codable, Sendable, Equatable {
    public var provider: String
    public var model: String
    public var sessionID: String
    public var startedAt: Date
    public var inputDeviceName: String
    public var microphoneModeName: String
    public var audioPreset: String
    public var localSpeakerIsolation: VoiceSessionConfig.AudioPolicy.LocalSpeakerIsolation
    public var appVersion: String
    public var buildVersion: String

    public init(
        provider: String,
        model: String,
        sessionID: String,
        startedAt: Date,
        inputDeviceName: String,
        microphoneModeName: String,
        audioPreset: String,
        localSpeakerIsolation: VoiceSessionConfig.AudioPolicy.LocalSpeakerIsolation,
        appVersion: String,
        buildVersion: String
    ) {
        self.provider = provider
        self.model = model
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.inputDeviceName = inputDeviceName
        self.microphoneModeName = microphoneModeName
        self.audioPreset = audioPreset
        self.localSpeakerIsolation = localSpeakerIsolation
        self.appVersion = appVersion
        self.buildVersion = buildVersion
    }
}

public struct VoiceSessionCaptureConfiguration: Sendable, Equatable {
    public var directoryURL: URL
    public var metadata: VoiceSessionCaptureMetadata
    public var rawInputSampleRate: Int
    public var enhancedSampleRate: Int?
    public var uplinkSampleRate: Int
    public var downlinkSampleRate: Int

    public init(
        directoryURL: URL,
        metadata: VoiceSessionCaptureMetadata,
        rawInputSampleRate: Int,
        enhancedSampleRate: Int? = nil,
        uplinkSampleRate: Int,
        downlinkSampleRate: Int
    ) {
        self.directoryURL = directoryURL
        self.metadata = metadata
        self.rawInputSampleRate = rawInputSampleRate
        self.enhancedSampleRate = enhancedSampleRate
        self.uplinkSampleRate = uplinkSampleRate
        self.downlinkSampleRate = downlinkSampleRate
    }
}

public struct VoiceSessionCaptureEvent: Codable, Sendable, Equatable {
    public enum Category: String, Codable, Sendable {
        case lifecycle
        case transcript
        case provider
        case interruption
        case capture
        case error
    }

    public var timestamp: Date
    public var category: Category
    public var message: String
    public var metadata: [String: String]

    public init(
        timestamp: Date = .now,
        category: Category,
        message: String,
        metadata: [String: String] = [:]
    ) {
        self.timestamp = timestamp
        self.category = category
        self.message = message
        self.metadata = metadata
    }
}

public struct UplinkAudioPipelineMetrics: Sendable, Equatable {
    public var chunkCount: Int = 0
    public var emittedChunkCount: Int = 0
    public var enhancedChunkCount: Int = 0
    public var rawInputByteCount: Int = 0
    public var uplinkByteCount: Int = 0
    public var engineMetrics: SpeakerIsolationEngineMetrics = .init()

    public init() {}
}
