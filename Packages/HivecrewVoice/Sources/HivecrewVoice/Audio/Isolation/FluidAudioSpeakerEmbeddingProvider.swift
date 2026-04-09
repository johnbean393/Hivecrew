import Foundation
import FluidAudio

public enum FluidAudioSpeakerEmbeddingError: Error {
    case invalidSampleWindow
    case emptyEmbedding
}

public protocol SpeakerEmbeddingProviding: Sendable {
    func prepare() async throws
    func distance(
        between profile: SpeakerIsolationProfile,
        and samples: [Float]
    ) async throws -> Float
}

public actor FluidAudioSpeakerEmbeddingProvider: SpeakerEmbeddingProviding {
    public static let shared = FluidAudioSpeakerEmbeddingProvider()
    public static let modelIdentifier = "FluidAudio.DiarizerManager.v0.13.6"

    private var diarizer: DiarizerManager?

    public init() {}

    public func prepare() async throws {
        guard diarizer == nil else { return }
        let models = try await DiarizerModels.downloadIfNeeded()
        let manager = DiarizerManager()
        manager.initialize(models: models)
        diarizer = manager
    }

    public func extractEmbedding(from samples: [Float]) async throws -> [Float] {
        guard samples.count >= 8_000 else { throw FluidAudioSpeakerEmbeddingError.invalidSampleWindow }
        try await prepare()
        guard let diarizer else { throw FluidAudioSpeakerEmbeddingError.invalidSampleWindow }
        let embedding = try diarizer.extractSpeakerEmbedding(from: samples)
        guard !embedding.isEmpty else { throw FluidAudioSpeakerEmbeddingError.emptyEmbedding }
        return PCMUtilities.normalize(embedding)
    }

    public func buildProfile(
        fromPCM16Data data: Data,
        sampleRate: Double,
        displayName: String = "Primary User"
    ) async throws -> SpeakerIsolationProfile {
        let floatSamples = PCMUtilities.pcm16MonoToFloat32(data)
        let normalized = PCMUtilities.resampleLinear(floatSamples, from: sampleRate, to: 16_000)
        return try await buildProfile(fromFloat32Samples: normalized, displayName: displayName)
    }

    public func buildProfile(
        fromFloat32Samples samples: [Float],
        displayName: String = "Primary User"
    ) async throws -> SpeakerIsolationProfile {
        let preparedSamples = trimSilence(samples)
        guard preparedSamples.count >= 16_000 else {
            throw FluidAudioSpeakerEmbeddingError.invalidSampleWindow
        }

        let windowSize = 32_000
        let stepSize = 16_000
        var windows: [[Float]] = []
        var index = 0
        while index + windowSize <= preparedSamples.count {
            windows.append(Array(preparedSamples[index..<(index + windowSize)]))
            index += stepSize
        }
        if windows.isEmpty {
            windows = [preparedSamples]
        }

        var embeddings: [[Float]] = []
        for window in windows {
            if let embedding = try? await extractEmbedding(from: window) {
                embeddings.append(embedding)
            }
        }

        if embeddings.isEmpty {
            embeddings = [try await extractEmbedding(from: preparedSamples)]
        }

        return SpeakerIsolationProfile(
            id: UUID().uuidString.lowercased(),
            displayName: displayName,
            embedding: PCMUtilities.normalizedAverage(embeddings),
            enrolledAt: .now,
            modelIdentifier: Self.modelIdentifier,
            sampleRate: 16_000,
            sampleCount: preparedSamples.count
        )
    }

    public func distance(
        between profile: SpeakerIsolationProfile,
        and samples: [Float]
    ) async throws -> Float {
        let embedding = try await extractEmbedding(from: samples)
        return PCMUtilities.cosineDistance(profile.embedding, embedding)
    }

    private func trimSilence(_ samples: [Float]) -> [Float] {
        let threshold: Float = 0.01
        guard let first = samples.firstIndex(where: { abs($0) > threshold }),
              let last = samples.lastIndex(where: { abs($0) > threshold }) else {
            return samples
        }
        return Array(samples[first...last])
    }
}
