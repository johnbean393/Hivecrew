import Testing
@testable import HivecrewVoice
import Foundation

@MainActor
@Test func openAISessionUpdateEncodesProviderOwnedVADPolicy() async throws {
    let provider = OpenAIRealtimeProvider()
    provider.configure(apiKey: "test")

    let config = VoiceSessionConfig(
        voiceName: "marin",
        audioPolicy: .init(
            preset: .noisyRoom,
            openAI: .init(
                turnDetection: .server(
                    threshold: 0.72,
                    prefixPaddingMs: 320,
                    silenceDurationMs: 680
                ),
                createResponse: true,
                interruptResponse: true,
                noiseReduction: .farField
            )
        )
    )

    let sessionUpdate = provider.buildSessionUpdate(config: config)

    #expect(sessionUpdate.session.audio?.input?.turnDetection?.type == "server_vad")
    #expect(sessionUpdate.session.audio?.input?.turnDetection?.threshold == 0.72)
    #expect(sessionUpdate.session.audio?.input?.turnDetection?.prefixPaddingMs == 320)
    #expect(sessionUpdate.session.audio?.input?.turnDetection?.silenceDurationMs == 680)
    #expect(sessionUpdate.session.audio?.input?.noiseReduction?.type == "far_field")
}

@MainActor
@Test func geminiSessionConfigEncodesAutomaticDetectionPolicy() async throws {
    let provider = GeminiLiveProvider()
    provider.configure(apiKey: "test")

    let config = VoiceSessionConfig(
        voiceName: "Leda",
        audioPolicy: .init(
            preset: .noisyRoom,
            gemini: .init(
                automaticActivityDetectionEnabled: true,
                startOfSpeechSensitivity: .low,
                endOfSpeechSensitivity: .low,
                prefixPaddingMs: 180,
                silenceDurationMs: 700,
                activityHandling: .startOfActivityInterrupts,
                turnCoverage: .audioActivityAndAllVideo
            )
        )
    )

    let sessionConfig = provider.buildSessionConfig(config: config, resumeHandle: nil)

    #expect(sessionConfig.realtimeInputConfig?.automaticActivityDetection?.disabled == false)
    #expect(sessionConfig.realtimeInputConfig?.automaticActivityDetection?.startOfSpeechSensitivity == "START_SENSITIVITY_LOW")
    #expect(sessionConfig.realtimeInputConfig?.automaticActivityDetection?.endOfSpeechSensitivity == "END_SENSITIVITY_LOW")
    #expect(sessionConfig.realtimeInputConfig?.automaticActivityDetection?.prefixPaddingMs == 180)
    #expect(sessionConfig.realtimeInputConfig?.automaticActivityDetection?.silenceDurationMs == 700)
    #expect(sessionConfig.realtimeInputConfig?.turnCoverage == "TURN_INCLUDES_AUDIO_ACTIVITY_AND_ALL_VIDEO")
}

@Test func audioPolicyConvenienceBuildersPreserveAutomaticProviderVAD() async throws {
    let semantic = VoiceSessionConfig.AudioPolicy.OpenAI.TurnDetection.semantic(eagerness: .low)
    let server = VoiceSessionConfig.AudioPolicy.OpenAI.TurnDetection.server(
        threshold: 0.6,
        prefixPaddingMs: 250,
        silenceDurationMs: 650
    )

    #expect(semantic.mode == .semanticVAD)
    #expect(semantic.eagerness == .low)
    #expect(server.mode == .serverVAD)
    #expect(server.threshold == 0.6)
    #expect(server.prefixPaddingMs == 250)
    #expect(server.silenceDurationMs == 650)
}

@MainActor
@Test func recommendedPresetUsesMicrophoneKind() async throws {
    #expect(AudioManager.recommendedPreset(for: .builtIn) == .noisyRoom)
    #expect(AudioManager.recommendedPreset(for: .external) == .balanced)
    #expect(AudioManager.recommendedPreset(for: .aggregate) == .balanced)
    #expect(AudioManager.recommendedPreset(for: .virtual) == .balanced)
    #expect(AudioManager.recommendedPreset(for: .unknown) == .balanced)
    #expect(AudioManager.recommendedPreset(for: nil) == .balanced)
}

@Test func localSpeakerIsolationPolicyDefaultsAreStrict() async throws {
    let policy = VoiceSessionConfig.AudioPolicy().localSpeakerIsolation
    #expect(policy.enabled)
    #expect(policy.strictMode)
    #expect(policy.internalSampleRate == 16_000)
    #expect(policy.extractorKind == .baselinePassthrough)
    #expect(policy.speechEnhancerKind == .hush)
    #expect(policy.profileUpdatePolicy == .highConfidenceOnly)
    #expect(policy.confidenceThresholds.pass == 0.60)
    #expect(policy.confidenceThresholds.attenuate == 0.70)
    #expect(policy.confidenceThresholds.mute == 0.95)
}

@Test func speakerIsolationEngineStrictMutesNonTargetSpeech() async throws {
    let engine = SpeakerIsolationEngine(
        embeddingProvider: FixedDistanceEmbeddingProvider(distance: 0.92),
        extractor: PassthroughTargetSpeakerExtractor()
    )
    let profile = SpeakerIsolationProfile(
        id: "test",
        embedding: Array(repeating: 0.1, count: 256),
        modelIdentifier: "test",
        sampleRate: 16_000,
        sampleCount: 16_000
    )
    let policy = VoiceSessionConfig.AudioPolicy.LocalSpeakerIsolation()

    let decision = await engine.evaluateDecision(
        analysisSamples: Array(repeating: 0.25, count: 16_000),
        targetProfile: profile,
        policy: policy,
        usedHoldback: true
    )
    #expect(decision.gate == .mute)

    let processed = await engine.applyDecision(
        decision,
        to: [0.6, -0.6, 0.2],
        targetProfile: profile,
        sampleRate: 16_000
    )
    #expect(processed.count == 3)
    #expect(processed[0] == 0)
    #expect(processed[1] == 0)
    #expect(processed[2] == 0)
}

@Test func speakerIsolationEnginePassesTargetSpeaker() async throws {
    let engine = SpeakerIsolationEngine(
        embeddingProvider: FixedDistanceEmbeddingProvider(distance: 0.20),
        extractor: PassthroughTargetSpeakerExtractor()
    )
    let profile = SpeakerIsolationProfile(
        id: "test",
        embedding: Array(repeating: 0.1, count: 256),
        modelIdentifier: "test",
        sampleRate: 16_000,
        sampleCount: 16_000
    )
    let policy = VoiceSessionConfig.AudioPolicy.LocalSpeakerIsolation()

    let decision = await engine.evaluateDecision(
        analysisSamples: Array(repeating: 0.25, count: 16_000),
        targetProfile: profile,
        policy: policy,
        usedHoldback: true
    )
    #expect(decision.gate == .pass)

    let processed = await engine.applyDecision(
        decision,
        to: [0.6, -0.6, 0.2],
        targetProfile: profile,
        sampleRate: 16_000
    )
    #expect(processed == [0.6, -0.6, 0.2])
}

@Test func speakerIsolationEngineAttenuatesUncertainSpeech() async throws {
    let engine = SpeakerIsolationEngine(
        embeddingProvider: FixedDistanceEmbeddingProvider(distance: 0.65),
        extractor: PassthroughTargetSpeakerExtractor()
    )
    let profile = SpeakerIsolationProfile(
        id: "test",
        embedding: Array(repeating: 0.1, count: 256),
        modelIdentifier: "test",
        sampleRate: 16_000,
        sampleCount: 16_000
    )
    let policy = VoiceSessionConfig.AudioPolicy.LocalSpeakerIsolation()

    let decision = await engine.evaluateDecision(
        analysisSamples: Array(repeating: 0.25, count: 16_000),
        targetProfile: profile,
        policy: policy,
        usedHoldback: true
    )
    #expect(decision.gate == .attenuate)
}

@Test func uplinkAudioPipelineUpsamplesForOpenAI() async throws {
    let policy = VoiceSessionConfig.AudioPolicy.LocalSpeakerIsolation(
        analysisWindowMs: 10,
        decisionStrideMs: 10,
        outputHoldbackMs: 1
    )
    let profile = SpeakerIsolationProfile(
        id: "test",
        embedding: Array(repeating: 0.1, count: 256),
        modelIdentifier: "test",
        sampleRate: 16_000,
        sampleCount: 16_000
    )
    let sink = OutputSink()
    let pipeline = UplinkAudioPipeline(
        configuration: .init(
            providerInputSampleRate: 24_000,
            captureSampleRate: 16_000,
            targetProfile: profile,
            policy: policy
        ),
        engine: SpeakerIsolationEngine(
            embeddingProvider: FixedDistanceEmbeddingProvider(distance: 0.12),
            extractor: PassthroughTargetSpeakerExtractor()
        ),
        outputHandler: { data, metadata in
            await sink.append(data: data, metadata: metadata)
        }
    )

    try await pipeline.prepare()
    let captureChunk = PCMUtilities.float32ToPCM16Mono(Array(repeating: 0.2, count: 160))
    await pipeline.enqueueCapturedPCM(captureChunk)
    let outputs = await sink.outputs()
    #expect(outputs.count == 1)
    #expect(outputs[0].0.count == 480)
    #expect(outputs[0].1.decision.gate == .pass)
}

@Test func uplinkAudioPipelineDoesNotClipInitialChunkBeforeFirstDecision() async throws {
    let policy = VoiceSessionConfig.AudioPolicy.LocalSpeakerIsolation(
        analysisWindowMs: 900,
        decisionStrideMs: 180,
        outputHoldbackMs: 300
    )
    let profile = SpeakerIsolationProfile(
        id: "test",
        embedding: Array(repeating: 0.1, count: 256),
        modelIdentifier: "test",
        sampleRate: 16_000,
        sampleCount: 16_000
    )
    let sink = OutputSink()
    let pipeline = UplinkAudioPipeline(
        configuration: .init(
            providerInputSampleRate: 16_000,
            captureSampleRate: 16_000,
            targetProfile: profile,
            policy: policy
        ),
        engine: SpeakerIsolationEngine(
            embeddingProvider: FixedDistanceEmbeddingProvider(distance: 0.95),
            extractor: PassthroughTargetSpeakerExtractor()
        ),
        outputHandler: { data, metadata in
            await sink.append(data: data, metadata: metadata)
        }
    )

    try await pipeline.prepare()
    let captureChunk = PCMUtilities.float32ToPCM16Mono(Array(repeating: 0.2, count: 320))
    for _ in 0..<15 {
        await pipeline.enqueueCapturedPCM(captureChunk)
    }
    let outputs = await sink.outputs()
    #expect(outputs.count >= 1)
    #expect(outputs[0].1.decision.gate == .pass)
}

@Test func uplinkAudioPipelineRoutesThroughSpeechEnhancer() async throws {
    let policy = VoiceSessionConfig.AudioPolicy.LocalSpeakerIsolation(
        analysisWindowMs: 10,
        decisionStrideMs: 10,
        outputHoldbackMs: 1
    )
    let profile = SpeakerIsolationProfile(
        id: "test",
        embedding: Array(repeating: 0.1, count: 256),
        modelIdentifier: "test",
        sampleRate: 16_000,
        sampleCount: 16_000
    )
    let enhancer = MockSpeechEnhancer(scaleFactor: 0.5)
    let sink = OutputSink()
    let pipeline = UplinkAudioPipeline(
        configuration: .init(
            providerInputSampleRate: 16_000,
            captureSampleRate: 16_000,
            targetProfile: profile,
            policy: policy
        ),
        engine: SpeakerIsolationEngine(
            embeddingProvider: FixedDistanceEmbeddingProvider(distance: 0.12),
            extractor: PassthroughTargetSpeakerExtractor()
        ),
        speechEnhancer: enhancer,
        outputHandler: { data, metadata in
            await sink.append(data: data, metadata: metadata)
        }
    )

    try await pipeline.prepare()
    let captureChunk = PCMUtilities.float32ToPCM16Mono(Array(repeating: 0.4, count: 160))
    await pipeline.enqueueCapturedPCM(captureChunk)

    let prepared = await enhancer.wasPrepared()
    #expect(prepared)

    let enhanceCount = await enhancer.callCount()
    #expect(enhanceCount == 1)

    let outputs = await sink.outputs()
    #expect(outputs.count == 1)

    let outputSamples = PCMUtilities.pcm16MonoToFloat32(outputs[0].0)
    #expect(!outputSamples.isEmpty)
    let maxSample = outputSamples.max() ?? 0
    #expect(maxSample > 0.3, "Output should use raw audio, not enhanced")
}

@Test func speakerIsolationEngineCanMuteWithRealExtractor() async throws {
    let engine = SpeakerIsolationEngine(
        embeddingProvider: FixedDistanceEmbeddingProvider(distance: 0.92),
        extractor: FakeHardMuteExtractor()
    )
    let profile = SpeakerIsolationProfile(
        id: "test",
        embedding: Array(repeating: 0.1, count: 256),
        modelIdentifier: "test",
        sampleRate: 16_000,
        sampleCount: 16_000
    )
    let policy = VoiceSessionConfig.AudioPolicy.LocalSpeakerIsolation()

    let decision = await engine.evaluateDecision(
        analysisSamples: Array(repeating: 0.25, count: 16_000),
        targetProfile: profile,
        policy: policy,
        usedHoldback: true
    )
    #expect(decision.gate == .mute)
}

@Test func speechEnhancerKindDefaultsToHush() async throws {
    let policy = VoiceSessionConfig.AudioPolicy.LocalSpeakerIsolation()
    #expect(policy.speechEnhancerKind == .hush)

    let nonePolicy = VoiceSessionConfig.AudioPolicy.LocalSpeakerIsolation(speechEnhancerKind: .none)
    #expect(nonePolicy.speechEnhancerKind == .none)
}

@Test func speechEnhancerKindEncodesAndDecodes() async throws {
    let policy = VoiceSessionConfig.AudioPolicy.LocalSpeakerIsolation(speechEnhancerKind: .hush)
    let encoder = JSONEncoder()
    let data = try encoder.encode(policy)
    let decoder = JSONDecoder()
    let decoded = try decoder.decode(VoiceSessionConfig.AudioPolicy.LocalSpeakerIsolation.self, from: data)
    #expect(decoded.speechEnhancerKind == .hush)
    #expect(decoded == policy)
}

@Test func voiceSessionCaptureWriterPersistsArtifacts() async throws {
    let baseURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let metadata = VoiceSessionCaptureMetadata(
        provider: "gemini_live",
        model: "gemini-3.1-flash-live-preview",
        sessionID: "session-1",
        startedAt: .now,
        inputDeviceName: "Built-in Microphone",
        microphoneModeName: "Voice Isolation",
        audioPreset: "noisy_room",
        localSpeakerIsolation: .init(),
        appVersion: "1.0",
        buildVersion: "1"
    )
    let writer = try VoiceSessionCaptureWriter(
        configuration: .init(
            directoryURL: baseURL,
            metadata: metadata,
            rawInputSampleRate: 16_000,
            enhancedSampleRate: 16_000,
            uplinkSampleRate: 24_000,
            downlinkSampleRate: 24_000
        )
    )

    await writer.record(.init(category: .lifecycle, message: "started"))
    await writer.appendRawInputPCM(Data(repeating: 1, count: 64))
    await writer.appendEnhancedPCM(Data(repeating: 4, count: 64))
    await writer.appendUplinkPCM(Data(repeating: 2, count: 64))
    await writer.appendDownlinkPCM(Data(repeating: 3, count: 64))
    await writer.finish()

    let eventsURL = baseURL.appendingPathComponent("events.jsonl")
    let rawWavURL = baseURL.appendingPathComponent("input_raw.wav")
    let enhancedWavURL = baseURL.appendingPathComponent("input_enhanced.wav")
    let metadataURL = baseURL.appendingPathComponent("metadata.json")
    #expect(FileManager.default.fileExists(atPath: eventsURL.path))
    #expect(FileManager.default.fileExists(atPath: rawWavURL.path))
    #expect(FileManager.default.fileExists(atPath: enhancedWavURL.path))
    #expect(FileManager.default.fileExists(atPath: metadataURL.path))

    let rawHeader = try Data(contentsOf: rawWavURL).prefix(4)
    #expect(String(data: rawHeader, encoding: .ascii) == "RIFF")

    let enhancedHeader = try Data(contentsOf: enhancedWavURL).prefix(4)
    #expect(String(data: enhancedHeader, encoding: .ascii) == "RIFF")

    let enhancedData = try Data(contentsOf: enhancedWavURL)
    #expect(enhancedData.count == 44 + 64)
}

@Test func voiceSessionCaptureWriterOmitsEnhancedWhenNoRate() async throws {
    let baseURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let metadata = VoiceSessionCaptureMetadata(
        provider: "openai_realtime",
        model: "gpt-4o-realtime",
        sessionID: "session-2",
        startedAt: .now,
        inputDeviceName: "Built-in Microphone",
        microphoneModeName: "Standard",
        audioPreset: "balanced",
        localSpeakerIsolation: .init(speechEnhancerKind: .none),
        appVersion: "1.0",
        buildVersion: "1"
    )
    let writer = try VoiceSessionCaptureWriter(
        configuration: .init(
            directoryURL: baseURL,
            metadata: metadata,
            rawInputSampleRate: 16_000,
            uplinkSampleRate: 24_000,
            downlinkSampleRate: 24_000
        )
    )

    await writer.appendRawInputPCM(Data(repeating: 1, count: 32))
    await writer.finish()

    let enhancedWavURL = baseURL.appendingPathComponent("input_enhanced.wav")
    #expect(!FileManager.default.fileExists(atPath: enhancedWavURL.path))
}

// MARK: - Test Doubles

private struct FixedDistanceEmbeddingProvider: SpeakerEmbeddingProviding {
    let distance: Float

    func prepare() async throws {}

    func distance(
        between profile: SpeakerIsolationProfile,
        and samples: [Float]
    ) async throws -> Float {
        distance
    }
}

private actor OutputSink {
    private var stored: [(Data, UplinkAudioChunkMetadata)] = []

    func append(data: Data, metadata: UplinkAudioChunkMetadata) {
        stored.append((data, metadata))
    }

    func outputs() -> [(Data, UplinkAudioChunkMetadata)] {
        stored
    }
}

private actor FakeHardMuteExtractor: TargetSpeakerExtractor {
    let descriptor = TargetSpeakerExtractorDescriptor(
        family: "TestExtractor",
        implementation: "voicefilter_lite",
        notes: "Test-only extractor descriptor"
    )

    func prepare() async throws {}

    func extract(samples: [Float], targetProfile: SpeakerIsolationProfile, sampleRate: Double) async throws -> [Float] {
        samples
    }
}

private actor MockSpeechEnhancer: SpeechEnhancer {
    let scaleFactor: Float
    private var prepared = false
    private var enhanceCalls = 0

    init(scaleFactor: Float) {
        self.scaleFactor = scaleFactor
    }

    func prepare() async throws {
        prepared = true
    }

    func enhance(_ samples: [Float], sampleRate: Double) async throws -> [Float] {
        enhanceCalls += 1
        return samples.map { $0 * scaleFactor }
    }

    func reset() async {}
    func shutdown() async {}

    func wasPrepared() -> Bool { prepared }
    func callCount() -> Int { enhanceCalls }
}
