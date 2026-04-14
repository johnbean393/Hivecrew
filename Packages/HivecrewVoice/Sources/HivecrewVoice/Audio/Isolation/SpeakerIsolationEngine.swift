import Foundation

public actor SpeakerIsolationEngine {
    private let embeddingProvider: any SpeakerEmbeddingProviding
    private let extractor: any TargetSpeakerExtractor
    private var metrics = SpeakerIsolationEngineMetrics()
    private var lastConfidentMatchAt: Date?

    public init(
        embeddingProvider: any SpeakerEmbeddingProviding,
        extractor: any TargetSpeakerExtractor
    ) {
        self.embeddingProvider = embeddingProvider
        self.extractor = extractor
    }

    public func prepare() async throws {
        try await embeddingProvider.prepare()
        try await extractor.prepare()
    }

    public func evaluateDecision(
        analysisSamples: [Float],
        targetProfile: SpeakerIsolationProfile,
        policy: VoiceSessionConfig.AudioPolicy.LocalSpeakerIsolation,
        usedHoldback: Bool
    ) async -> SpeakerIsolationDecision {
        let power = PCMUtilities.averagePower(analysisSamples)
        guard power > 0.01 else {
            return recordDecision(
                .init(gate: .mute, distance: nil, analysisPower: power, usedHoldback: usedHoldback)
            )
        }

        do {
            let distance = try await embeddingProvider.distance(between: targetProfile, and: analysisSamples)
            let thresholds = policy.confidenceThresholds
            let gate: SpeakerIsolationGate
            if distance <= thresholds.pass {
                lastConfidentMatchAt = Date()
                gate = .pass
            } else if distance <= thresholds.attenuate {
                gate = recentlyMatchedTarget ? .pass : .attenuate
            } else if distance <= thresholds.mute {
                gate = .mute
            } else {
                gate = policy.strictMode ? .mute : .attenuate
            }
            return recordDecision(
                .init(gate: gate, distance: distance, analysisPower: power, usedHoldback: usedHoldback)
            )
        } catch {
            return recordDecision(
                .init(gate: policy.strictMode ? .mute : .attenuate, distance: nil, analysisPower: power, usedHoldback: usedHoldback)
            )
        }
    }

    public func applyDecision(
        _ decision: SpeakerIsolationDecision,
        to samples: [Float],
        targetProfile: SpeakerIsolationProfile,
        sampleRate: Double
    ) async -> [Float] {
        let extracted = (try? await extractor.extract(samples: samples, targetProfile: targetProfile, sampleRate: sampleRate)) ?? samples
        switch decision.gate {
        case .pass:
            return extracted
        case .attenuate:
            return PCMUtilities.scaled(extracted, gain: 0.35)
        case .mute:
            return PCMUtilities.silence(sampleCount: extracted.count)
        }
    }

    public func snapshotMetrics() -> SpeakerIsolationEngineMetrics {
        metrics
    }

    private func recordDecision(_ decision: SpeakerIsolationDecision) -> SpeakerIsolationDecision {
        metrics.decisionCount += 1
        switch decision.gate {
        case .pass:
            metrics.passCount += 1
        case .attenuate:
            metrics.attenuateCount += 1
        case .mute:
            metrics.muteCount += 1
        }
        if let distance = decision.distance {
            let previousTotal = metrics.averageDistance * Float(max(0, metrics.decisionCount - 1))
            metrics.averageDistance = (previousTotal + distance) / Float(metrics.decisionCount)
        }
        metrics.lastDecision = decision
        return decision
    }

    private var recentlyMatchedTarget: Bool {
        guard let lastConfidentMatchAt else { return false }
        return Date().timeIntervalSince(lastConfidentMatchAt) < 1.0
    }
}
