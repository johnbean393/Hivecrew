import Testing
@testable import HivecrewVoice
import Foundation

actor VoiceToolCallSink {
    private var calls: [VoiceToolCall] = []

    func record(_ call: VoiceToolCall) {
        calls.append(call)
    }

    func snapshot() -> [VoiceToolCall] {
        calls
    }
}

actor VoiceTranscriptionSink {
    private var transcriptions: [VoiceTranscription] = []

    func record(_ transcription: VoiceTranscription) {
        transcriptions.append(transcription)
    }

    func snapshot() -> [VoiceTranscription] {
        transcriptions
    }
}

@Test func openAICatalogIncludesRealtime2AsDefault() {
    #expect(RealtimeVoiceCatalog.defaultModelID(for: .openAIRealtime) == "gpt-realtime-2")
    #expect(RealtimeVoiceCatalog.openAIModels.map(\.id).contains("gpt-realtime-2"))
    #expect(RealtimeVoiceCatalog.openAIModels.map(\.id).contains("gpt-realtime-1.5"))
    #expect(RealtimeVoiceCatalog.openAIModels.first?.id == "gpt-realtime-2")
}

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
    #expect(sessionUpdate.session.model == "gpt-realtime-2")
    #expect(sessionUpdate.session.reasoning?.effort == "low")
}

@MainActor
@Test func openAISessionUpdateEncodesRealtime2ReasoningOnly() async throws {
    let provider = OpenAIRealtimeProvider()
    provider.configure(apiKey: "test", model: "gpt-realtime-2")

    let highReasoning = provider.buildSessionUpdate(
        config: VoiceSessionConfig(thinkingLevel: .high)
    )
    #expect(highReasoning.session.reasoning?.effort == "high")

    let minimalReasoning = provider.buildSessionUpdate(
        config: VoiceSessionConfig(thinkingLevel: .minimal)
    )
    #expect(minimalReasoning.session.reasoning?.effort == "low")

    provider.configure(apiKey: "test", model: "gpt-realtime-1.5")
    let previousRealtime = provider.buildSessionUpdate(
        config: VoiceSessionConfig(thinkingLevel: .high)
    )
    #expect(previousRealtime.session.model == "gpt-realtime-1.5")
    #expect(previousRealtime.session.reasoning?.effort == nil)
}

@MainActor
@Test func xAISessionUpdateEncodesVoiceAgentPayload() async throws {
    let provider = XAIRealtimeProvider()
    provider.configure(apiKey: "test")

    let config = VoiceSessionConfig(
        systemPrompt: "Help with Hivecrew tasks.",
        voiceName: "ara",
        tools: [
            .init(
                name: "create_task",
                description: "Create a task",
                parameters: .init(
                    type: "object",
                    properties: [
                        "description": .init(type: "string", description: "Task description")
                    ],
                    required: ["description"]
                )
            )
        ],
        webSearchEnabled: true,
        audioPolicy: .init(
            openAI: .init(
                turnDetection: .server(
                    threshold: 0.72,
                    prefixPaddingMs: 320,
                    silenceDurationMs: 680
                )
            )
        )
    )

    let sessionUpdate = provider.buildSessionUpdate(config: config)

    #expect(sessionUpdate.session.voice == "ara")
    #expect(sessionUpdate.session.instructions == "Help with Hivecrew tasks.")
    #expect(sessionUpdate.session.turnDetection?.type == "server_vad")
    #expect(sessionUpdate.session.turnDetection?.threshold == 0.72)
    #expect(sessionUpdate.session.inputAudioTranscription?.model == "grok-2-audio")
    #expect(sessionUpdate.session.audio?.input?.format?.type == "audio/pcm")
    #expect(sessionUpdate.session.audio?.input?.format?.rate == 24000)
    #expect(sessionUpdate.session.tools?.map(\.type) == ["web_search", "x_search", "function"])
    #expect(sessionUpdate.session.tools?.last?.name == "create_task")
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

@MainActor
@Test func geminiSessionConfigDoesNotIncludeProviderSideGoogleSearch() async throws {
    let provider = GeminiLiveProvider()
    provider.configure(apiKey: "test")

    let config = VoiceSessionConfig(
        voiceName: "Leda",
        tools: [
            .init(
                name: "search_files",
                description: "Search indexed files",
                parameters: .init(
                    type: "object",
                    properties: [
                        "query": .init(type: "string", description: "Search query")
                    ],
                    required: ["query"]
                )
            )
        ],
        webSearchEnabled: true
    )

    let sessionConfig = provider.buildSessionConfig(config: config, resumeHandle: nil)

    #expect(sessionConfig.tools?.count == 1)
    #expect(sessionConfig.tools?.first?.googleSearch == nil)
    #expect(sessionConfig.tools?.first?.functionDeclarations?.count == 1)
}

@MainActor
@Test func staleGeminiCloseCallbackDoesNotInterruptReconnect() async throws {
    let provider = GeminiLiveProvider()
    provider.configure(apiKey: "test")

    let oldSocket = makeTestGeminiWebSocketTask(provider: provider)
    let newSocket = makeTestGeminiWebSocketTask(provider: provider)
    provider.webSocket = newSocket
    provider.connectionState = .connecting

    let connectTask = Task {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            provider.connectionContinuation = continuation
        }
    }

    provider.urlSession(
        provider.urlSession,
        webSocketTask: oldSocket,
        didCloseWith: .goingAway,
        reason: nil
    )
    try await Task.sleep(for: .milliseconds(50))

    #expect(provider.webSocket === newSocket)
    #expect(provider.connectionState == .connecting)

    provider.urlSession(provider.urlSession, webSocketTask: newSocket, didOpenWithProtocol: nil)
    try await connectTask.value
}

@MainActor
@Test func staleGeminiTaskErrorDoesNotInterruptReconnect() async throws {
    let provider = GeminiLiveProvider()
    provider.configure(apiKey: "test")

    let oldSocket = makeTestGeminiWebSocketTask(provider: provider)
    let newSocket = makeTestGeminiWebSocketTask(provider: provider)
    provider.webSocket = newSocket
    provider.connectionState = .connecting

    let connectTask = Task {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            provider.connectionContinuation = continuation
        }
    }

    provider.urlSession(
        provider.urlSession,
        task: oldSocket,
        didCompleteWithError: TestURLSessionError.connectionLost
    )
    try await Task.sleep(for: .milliseconds(50))

    #expect(provider.webSocket === newSocket)
    #expect(provider.connectionState == .connecting)

    provider.urlSession(provider.urlSession, webSocketTask: newSocket, didOpenWithProtocol: nil)
    try await connectTask.value
}

@MainActor
@Test func geminiUsageMetadataReplacesSessionTotal() async throws {
    let provider = GeminiLiveProvider()
    provider.configure(apiKey: "test")

    await provider.parseServerMessage("""
    {"usageMetadata":{"totalTokenCount":120}}
    """)
    #expect(provider.totalTokenCount == 120)

    await provider.parseServerMessage("""
    {"usageMetadata":{"totalTokenCount":180}}
    """)
    #expect(provider.totalTokenCount == 180)
}

@MainActor
@Test func openAIStreamedFunctionCallArgumentsTriggerToolCall() async throws {
    let provider = OpenAIRealtimeProvider()
    provider.configure(apiKey: "test")

    let sink = VoiceToolCallSink()
    provider.onToolCall = { call in
        Task {
            await sink.record(call)
        }
    }

    await provider.parseServerEvent(
        #"""
        {
          "type": "response.function_call_arguments.done",
          "call_id": "call_123",
          "name": "create_task",
          "arguments": "{\"description\":\"Draft the release notes\",\"plan_first\":\"true\"}"
        }
        """#
    )

    try await Task.sleep(for: .milliseconds(20))
    let calls = await sink.snapshot()

    #expect(calls.count == 1)
    #expect(calls.first?.id == "call_123")
    #expect(calls.first?.name == "create_task")
    #expect(calls.first?.arguments["description"] == "Draft the release notes")
    #expect(calls.first?.arguments["plan_first"] == "true")
}

@MainActor
@Test func openAIToolCallIsDeduplicatedAcrossStreamedAndDoneEvents() async throws {
    let provider = OpenAIRealtimeProvider()
    provider.configure(apiKey: "test")

    let sink = VoiceToolCallSink()
    provider.onToolCall = { call in
        Task {
            await sink.record(call)
        }
    }

    await provider.parseServerEvent(
        #"""
        {
          "type": "response.function_call_arguments.done",
          "call_id": "call_456",
          "name": "create_task",
          "arguments": "{\"description\":\"Prepare the launch email\"}"
        }
        """#
    )

    await provider.parseServerEvent(
        #"""
        {
          "type": "response.done",
          "response": {
            "output": [
              {
                "type": "function_call",
                "call_id": "call_456",
                "name": "create_task",
                "arguments": "{\"description\":\"Prepare the launch email\"}"
              }
            ]
          }
        }
        """#
    )

    try await Task.sleep(for: .milliseconds(20))
    let calls = await sink.snapshot()

    #expect(calls.count == 1)
    #expect(calls.first?.id == "call_456")
    #expect(calls.first?.arguments["description"] == "Prepare the launch email")
}

@MainActor
@Test func openAIOutputTranscriptWaitsForInputTranscriptionAndDeduplicatesDone() async throws {
    let provider = OpenAIRealtimeProvider()
    provider.configure(apiKey: "test")

    let sink = VoiceTranscriptionSink()
    provider.onTranscription = { transcription in
        Task { await sink.record(transcription) }
    }

    await provider.parseServerEvent(
        #"""
        {
          "type": "input_audio_buffer.committed"
        }
        """#
    )

    await provider.parseServerEvent(
        #"""
        {
          "type": "response.output_audio_transcript.delta",
          "item_id": "msg_1",
          "delta": "Loud and clear"
        }
        """#
    )

    await provider.parseServerEvent(
        #"""
        {
          "type": "conversation.item.input_audio_transcription.completed",
          "item_id": "user_1",
          "transcript": "Hey there, can you hear me?"
        }
        """#
    )

    await provider.parseServerEvent(
        #"""
        {
          "type": "response.output_audio_transcript.delta",
          "item_id": "msg_1",
          "delta": "! How's it going?"
        }
        """#
    )

    await provider.parseServerEvent(
        #"""
        {
          "type": "response.output_audio_transcript.done",
          "item_id": "msg_1",
          "transcript": "Loud and clear! How's it going?"
        }
        """#
    )

    try await Task.sleep(for: .milliseconds(20))
    let transcriptions = await sink.snapshot()

    #expect(transcriptions.count == 3)
    #expect(transcriptions[0].source == .input)
    #expect(transcriptions[0].text == "Hey there, can you hear me?")
    #expect(transcriptions[1].source == .output)
    #expect(transcriptions[1].text == "Loud and clear")
    #expect(transcriptions[2].source == .output)
    #expect(transcriptions[2].text == "Loud and clear! How's it going?")
}

@MainActor
@Test func openAIInterruptedOutputTranscriptIgnoresStaleDone() async throws {
    let provider = OpenAIRealtimeProvider()
    provider.configure(apiKey: "test")

    let sink = VoiceTranscriptionSink()
    provider.onTranscription = { transcription in
        Task { await sink.record(transcription) }
    }

    await provider.parseServerEvent(
        #"""
        {
          "type": "response.output_audio_transcript.delta",
          "item_id": "msg_2",
          "delta": "Great! I'll keep you posted when Victor"
        }
        """#
    )

    await provider.parseServerEvent(
        #"""
        {
          "type": "input_audio_buffer.speech_started",
          "audio_start_ms": 120
        }
        """#
    )

    await provider.parseServerEvent(
        #"""
        {
          "type": "response.output_audio_transcript.done",
          "item_id": "msg_2",
          "transcript": "Great! I'll keep you posted when Victor finishes."
        }
        """#
    )

    await provider.parseServerEvent(
        #"""
        {
          "type": "conversation.item.input_audio_transcription.completed",
          "item_id": "user_2",
          "transcript": "Got it."
        }
        """#
    )

    try await Task.sleep(for: .milliseconds(20))
    let transcriptions = await sink.snapshot()

    #expect(transcriptions.count == 2)
    #expect(transcriptions[0].source == .output)
    #expect(transcriptions[0].text == "Great! I'll keep you posted when Victor")
    #expect(transcriptions[1].source == .input)
    #expect(transcriptions[1].text == "Got it.")
}

@MainActor
@Test func geminiMissingResumeHandleReportsTerminalDisconnect() async throws {
    let provider = GeminiLiveProvider()
    provider.configure(apiKey: "test")
    provider.shouldResumeSession = true
    provider.currentSessionConfig = VoiceSessionConfig()

    let sink = DisconnectSink()
    provider.onDisconnected = { event in
        Task { await sink.record(event) }
    }

    provider.resumeSessionIfNeeded()
    try? await Task.sleep(for: .milliseconds(20))
    let event = await sink.lastEvent()

    #expect(event?.message == "Connection to Gemini was lost")
    #expect(event?.recoverable == false)
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

@MainActor
@Test func audioManagerPlaybackGainScalesPCM16Samples() async throws {
    let samples: [Int16] = [1000, -2000, 5000, -5000]
    let input = samples.withUnsafeBufferPointer { Data(buffer: $0) }

    let scaled = AudioManager.scalePCM16Audio(input, gain: 0.6)
    let output = scaled.withUnsafeBytes { rawBuffer in
        Array(rawBuffer.bindMemory(to: Int16.self))
    }

    #expect(output == [600, -1200, 3000, -3000])
}

@MainActor
private func makeTestGeminiWebSocketTask(provider: GeminiLiveProvider) -> URLSessionWebSocketTask {
    provider.urlSession.webSocketTask(with: URL(string: "wss://example.com/socket")!)
}

private enum TestURLSessionError: LocalizedError {
    case connectionLost

    var errorDescription: String? {
        switch self {
        case .connectionLost:
            return "Connection lost"
        }
    }
}

actor DisconnectSink {
    private var event: VoiceDisconnectEvent?

    func record(_ event: VoiceDisconnectEvent) {
        self.event = event
    }

    func lastEvent() -> VoiceDisconnectEvent? {
        event
    }
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
