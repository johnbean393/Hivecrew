import Foundation

public struct UplinkAudioChunkMetadata: Sendable, Equatable {
    public var decision: SpeakerIsolationDecision
    public var rawInputBytes: Int
    public var emittedBytes: Int

    public init(decision: SpeakerIsolationDecision, rawInputBytes: Int, emittedBytes: Int) {
        self.decision = decision
        self.rawInputBytes = rawInputBytes
        self.emittedBytes = emittedBytes
    }
}

public struct UplinkAudioPipelineConfiguration: Sendable, Equatable {
    public var providerInputSampleRate: Double
    public var captureSampleRate: Double
    public var targetProfile: SpeakerIsolationProfile
    public var policy: VoiceSessionConfig.AudioPolicy.LocalSpeakerIsolation

    public init(
        providerInputSampleRate: Double,
        captureSampleRate: Double,
        targetProfile: SpeakerIsolationProfile,
        policy: VoiceSessionConfig.AudioPolicy.LocalSpeakerIsolation
    ) {
        self.providerInputSampleRate = providerInputSampleRate
        self.captureSampleRate = captureSampleRate
        self.targetProfile = targetProfile
        self.policy = policy
    }
}

public actor UplinkAudioPipeline {
    public typealias OutputHandler = @MainActor @Sendable (Data, UplinkAudioChunkMetadata) async -> Void
    public typealias DecisionHandler = @MainActor @Sendable (SpeakerIsolationDecision) -> Void

    private let configuration: UplinkAudioPipelineConfiguration
    private let engine: SpeakerIsolationEngine
    private let speechEnhancer: (any SpeechEnhancer)?
    private let outputHandler: OutputHandler
    private let decisionHandler: DecisionHandler?
    private let captureWriter: VoiceSessionCaptureWriter?

    private var rollingAnalysisSamples: [Float] = []
    private var holdbackQueue: [[Float]] = []
    private var samplesSinceDecision = 0
    // Start permissively so we do not clip the beginning of an utterance
    // before the first verification window is available.
    private var currentDecision = SpeakerIsolationDecision(gate: .pass, distance: nil)
    private var voicedDecisionsSinceLastSilence = 0
    private var metrics = UplinkAudioPipelineMetrics()

    public init(
        configuration: UplinkAudioPipelineConfiguration,
        engine: SpeakerIsolationEngine,
        speechEnhancer: (any SpeechEnhancer)? = nil,
        captureWriter: VoiceSessionCaptureWriter? = nil,
        decisionHandler: DecisionHandler? = nil,
        outputHandler: @escaping OutputHandler
    ) {
        self.configuration = configuration
        self.engine = engine
        self.speechEnhancer = speechEnhancer
        self.captureWriter = captureWriter
        self.decisionHandler = decisionHandler
        self.outputHandler = outputHandler
    }

    public func prepare() async throws {
        try await speechEnhancer?.prepare()
        try await engine.prepare()
    }

    public func enqueueCapturedPCM(_ data: Data) async {
        guard !data.isEmpty else { return }
        metrics.chunkCount += 1
        metrics.rawInputByteCount += data.count

        await captureWriter?.appendRawInputPCM(data)

        let captureSamples = PCMUtilities.pcm16MonoToFloat32(data)
        let internalSamples = PCMUtilities.resampleLinear(
            captureSamples,
            from: configuration.captureSampleRate,
            to: configuration.policy.internalSampleRate
        )
        guard !internalSamples.isEmpty else { return }

        var processedSamples = internalSamples
        if let speechEnhancer {
            processedSamples = (try? await speechEnhancer.enhance(
                internalSamples, sampleRate: configuration.policy.internalSampleRate
            )) ?? internalSamples
            metrics.enhancedChunkCount += 1
            let enhancedPCM = PCMUtilities.float32ToPCM16Mono(processedSamples)
            await captureWriter?.appendEnhancedPCM(enhancedPCM)
        }

        rollingAnalysisSamples.append(contentsOf: internalSamples)
        holdbackQueue.append(internalSamples)
        trimRollingBufferIfNeeded()
        samplesSinceDecision += internalSamples.count

        let strideSamples = samples(forMilliseconds: configuration.policy.decisionStrideMs)
        if samplesSinceDecision >= strideSamples,
           rollingAnalysisSamples.count >= samples(forMilliseconds: configuration.policy.analysisWindowMs) {
            samplesSinceDecision = 0
            let decision = await engine.evaluateDecision(
                analysisSamples: Array(rollingAnalysisSamples.suffix(samples(forMilliseconds: configuration.policy.analysisWindowMs))),
                targetProfile: configuration.targetProfile,
                policy: configuration.policy,
                usedHoldback: true
            )

            if decision.distance != nil {
                voicedDecisionsSinceLastSilence += 1
                if voicedDecisionsSinceLastSilence == 1 {
                    // First voiced frame after silence: start permissively
                    // while the analysis window is still mostly silence.
                    currentDecision = SpeakerIsolationDecision(gate: .pass, distance: nil)
                }
                let onsetFrames = max(2, configuration.policy.analysisWindowMs / configuration.policy.decisionStrideMs)
                if decision.gate != .pass && voicedDecisionsSinceLastSilence <= onsetFrames {
                    // Onset protection: analysis window is still filling with voice,
                    // distances are unreliable — keep permissive decision.
                } else {
                    currentDecision = decision
                }
            } else {
                voicedDecisionsSinceLastSilence = 0
                currentDecision = decision
            }
            await decisionHandler?(decision)
        }

        await flushHoldbackIfNeeded()
    }

    public func finish(flushPendingAudio: Bool = false) async -> UplinkAudioPipelineMetrics {
        if flushPendingAudio {
            while !holdbackQueue.isEmpty {
                await emitNextChunk(force: true)
            }
        } else {
            holdbackQueue.removeAll()
        }
        await speechEnhancer?.shutdown()
        metrics.engineMetrics = await engine.snapshotMetrics()
        return metrics
    }

    private func flushHoldbackIfNeeded() async {
        let requiredSamples = max(1, samples(forMilliseconds: configuration.policy.outputHoldbackMs))
        while !holdbackQueue.isEmpty && holdbackSampleCount >= requiredSamples {
            await emitNextChunk(force: false)
        }
    }

    private func emitNextChunk(force: Bool) async {
        guard !holdbackQueue.isEmpty else { return }
        let chunk = holdbackQueue.removeFirst()
        let processed = await engine.applyDecision(
            currentDecision,
            to: chunk,
            targetProfile: configuration.targetProfile,
            sampleRate: configuration.policy.internalSampleRate
        )

        let providerSamples = PCMUtilities.resampleLinear(
            processed,
            from: configuration.policy.internalSampleRate,
            to: configuration.providerInputSampleRate
        )
        let providerPCM = PCMUtilities.float32ToPCM16Mono(providerSamples)
        guard force || !providerPCM.isEmpty else { return }

        metrics.emittedChunkCount += 1
        metrics.uplinkByteCount += providerPCM.count
        metrics.engineMetrics = await engine.snapshotMetrics()

        await captureWriter?.appendUplinkPCM(providerPCM)
        await outputHandler(
            providerPCM,
            .init(
                decision: currentDecision,
                rawInputBytes: chunk.count * MemoryLayout<Float>.size,
                emittedBytes: providerPCM.count
            )
        )
    }

    private func trimRollingBufferIfNeeded() {
        let maxSamples = samples(forMilliseconds: configuration.policy.analysisWindowMs * 2)
        guard rollingAnalysisSamples.count > maxSamples else { return }
        rollingAnalysisSamples.removeFirst(rollingAnalysisSamples.count - maxSamples)
    }

    private var holdbackSampleCount: Int {
        holdbackQueue.reduce(0) { partial, chunk in partial + chunk.count }
    }

    private func samples(forMilliseconds milliseconds: Int) -> Int {
        Int((Double(milliseconds) / 1000.0) * configuration.policy.internalSampleRate)
    }
}
