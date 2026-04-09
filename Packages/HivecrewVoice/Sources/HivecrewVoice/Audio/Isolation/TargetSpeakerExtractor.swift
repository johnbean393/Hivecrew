import Foundation

public struct TargetSpeakerExtractorDescriptor: Codable, Sendable, Equatable {
    public var family: String
    public var implementation: String
    public var notes: String

    public init(family: String, implementation: String, notes: String) {
        self.family = family
        self.implementation = implementation
        self.notes = notes
    }
}

public protocol TargetSpeakerExtractor: Sendable {
    var descriptor: TargetSpeakerExtractorDescriptor { get }
    func prepare() async throws
    func extract(
        samples: [Float],
        targetProfile: SpeakerIsolationProfile,
        sampleRate: Double
    ) async throws -> [Float]
}

public actor PassthroughTargetSpeakerExtractor: TargetSpeakerExtractor {
    public let descriptor = TargetSpeakerExtractorDescriptor(
        family: "VoiceFilter-Lite",
        implementation: "baseline_passthrough",
        notes: "Uses personalized gating now and reserves the extractor interface for a future CoreML target-speaker model."
    )

    public init() {}

    public func prepare() async throws {}

    public func extract(
        samples: [Float],
        targetProfile: SpeakerIsolationProfile,
        sampleRate: Double
    ) async throws -> [Float] {
        samples
    }
}
