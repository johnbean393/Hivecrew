import Foundation

/// Pre-processes raw microphone audio to suppress background speakers and noise
/// at the waveform level, before speaker-embedding verification runs.
///
/// Distinct from ``TargetSpeakerExtractor`` which uses a speaker embedding to
/// isolate a specific target voice.  A `SpeechEnhancer` operates without any
/// enrolled profile -- it enhances the acoustically dominant speaker.
public protocol SpeechEnhancer: Sendable {
    func prepare() async throws
    func enhance(_ samples: [Float], sampleRate: Double) async throws -> [Float]
    func reset() async
    func shutdown() async
}
