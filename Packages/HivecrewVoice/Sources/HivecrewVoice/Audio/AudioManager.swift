//
//  AudioManager.swift
//  HivecrewVoice
//
//  Uses Apple VoiceProcessingIO audio unit for hardware-level echo
//  cancellation, following the pattern from AECAudioStream.
//  Replaces the previous dual-engine + WebRTC AEC approach.
//

import Foundation
@preconcurrency import AVFoundation
import AudioToolbox

// MARK: - VoiceProcessingIO Bridge

/// Shared state accessed by VPIO audio-thread callbacks.
/// All audio-thread access is single-threaded (one callback at a time).
/// Playback buffer uses its own lock for cross-thread writes.
private final class VPIOBridge: @unchecked Sendable {
    var audioUnit: AudioUnit?

    // Capture state (accessed only from input callback thread)
    let muteBox: MuteStateBox
    let inputLevelBox: LevelBox
    let minSendSize: Int
    let vpioRate: Double
    let targetCaptureRate: Double
    var captureAccumulator = Data()
    var captureCallback: (@Sendable (Data) -> Void)?

    // Playback ring buffer (written from main, read from render callback)
    private let pbLock = NSLock()
    private var pbBuffer = Data()
    let outputLevelBox: LevelBox

    init(muteBox: MuteStateBox, minSendSize: Int, vpioRate: Double, targetCaptureRate: Double) {
        self.muteBox = muteBox
        self.inputLevelBox = LevelBox()
        self.outputLevelBox = LevelBox()
        self.minSendSize = minSendSize
        self.vpioRate = vpioRate
        self.targetCaptureRate = targetCaptureRate
    }

    func writePlayback(_ data: Data) {
        pbLock.lock()
        pbBuffer.append(data)
        pbLock.unlock()
    }

    func readPlayback(count: Int) -> Data {
        pbLock.lock()
        if pbBuffer.isEmpty {
            pbLock.unlock()
            return Data(count: count)
        }
        let available = min(count, pbBuffer.count)
        let chunk = Data(pbBuffer.prefix(available))
        pbBuffer.removeFirst(available)
        pbLock.unlock()
        if available < count {
            return chunk + Data(count: count - available)
        }
        return chunk
    }

    func clearPlayback() {
        pbLock.lock()
        pbBuffer.removeAll()
        pbLock.unlock()
    }

    var isPlaybackEmpty: Bool {
        pbLock.lock()
        defer { pbLock.unlock() }
        return pbBuffer.isEmpty
    }
}

private final class MuteStateBox: @unchecked Sendable {
    let lock = NSLock()
    var value = false
}

private final class LevelBox: @unchecked Sendable {
    let lock = NSLock()
    var level: Float = 0
    func update(_ v: Float) { lock.lock(); level = v; lock.unlock() }
    func read() -> Float { lock.lock(); defer { lock.unlock() }; return level }
}

// MARK: - VPIO Callbacks (file-scope, no captures)

private func vpioInputCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let bridge = Unmanaged<VPIOBridge>.fromOpaque(inRefCon).takeUnretainedValue()

    guard let audioUnit = bridge.audioUnit else { return kAudio_ParamError }

    let audioBuffer = AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil)
    var bufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: audioBuffer)

    let status = AudioUnitRender(audioUnit, ioActionFlags, inTimeStamp, 1, inNumberFrames, &bufferList)
    guard status == noErr else { return status }

    bridge.muteBox.lock.lock()
    let muted = bridge.muteBox.value
    bridge.muteBox.lock.unlock()
    if muted { return noErr }

    let mBuf = bufferList.mBuffers
    guard let mData = mBuf.mData, mBuf.mDataByteSize > 0 else { return noErr }

    let byteCount = Int(mBuf.mDataByteSize)

    bridge.inputLevelBox.update(levelFromInt16(mData, byteCount: byteCount))

    let raw = Data(bytes: mData, count: byteCount)
    let resampled: Data
    if abs(bridge.vpioRate - bridge.targetCaptureRate) < 1.0 {
        resampled = raw
    } else {
        resampled = resampleInt16Mono(raw, from: bridge.vpioRate, to: bridge.targetCaptureRate)
    }

    bridge.captureAccumulator.append(resampled)
    if bridge.captureAccumulator.count >= bridge.minSendSize {
        let chunk = bridge.captureAccumulator
        bridge.captureAccumulator.removeAll(keepingCapacity: true)
        bridge.captureCallback?(chunk)
    }

    return noErr
}

private func vpioRenderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let bridge = Unmanaged<VPIOBridge>.fromOpaque(inRefCon).takeUnretainedValue()

    guard let ioData else { return kAudio_ParamError }

    let bytesNeeded = Int(inNumberFrames) * 2
    let data = bridge.readPlayback(count: bytesNeeded)

    data.withUnsafeBytes { src in
        guard let srcBase = src.baseAddress else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        for buf in buffers {
            guard let dst = buf.mData else { continue }
            let copyCount = min(Int(buf.mDataByteSize), data.count)
            memcpy(dst, srcBase, copyCount)
        }
    }

    bridge.outputLevelBox.update(levelFromInt16Data(data))

    return noErr
}

// MARK: - Helpers (file-scope, audio-thread safe)

private func levelFromInt16(_ ptr: UnsafeMutableRawPointer, byteCount: Int) -> Float {
    let samples = ptr.assumingMemoryBound(to: Int16.self)
    let count = byteCount / MemoryLayout<Int16>.size
    guard count > 0 else { return 0 }
    var sum: Float = 0
    for i in 0..<count {
        let s = Float(samples[i]) / 32768.0
        sum += s * s
    }
    let rms = sqrt(sum / Float(count))
    let avgPower = 20 * log10(max(rms, 0.0001))
    return max(0, min(1, (avgPower + 65) / 65))
}

private func levelFromInt16Data(_ data: Data) -> Float {
    let count = data.count / MemoryLayout<Int16>.size
    guard count > 0 else { return 0 }
    return data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return Float(0) }
        return levelFromInt16(UnsafeMutableRawPointer(mutating: base), byteCount: data.count)
    }
}

private func resampleInt16Mono(_ data: Data, from sourceRate: Double, to targetRate: Double) -> Data {
    let bytesPerSample = 2
    let sampleCount = data.count / bytesPerSample
    guard sampleCount > 0 else { return data }

    let targetCount = max(1, Int((Double(sampleCount) * targetRate / sourceRate).rounded()))
    var output = Data(count: targetCount * bytesPerSample)

    data.withUnsafeBytes { srcRaw in
        output.withUnsafeMutableBytes { dstRaw in
            guard let src = srcRaw.baseAddress?.assumingMemoryBound(to: Int16.self),
                  let dst = dstRaw.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for i in 0..<targetCount {
                let srcPos = Double(i) * sourceRate / targetRate
                let lo = min(sampleCount - 1, Int(srcPos))
                let hi = min(sampleCount - 1, lo + 1)
                let frac = Float(srcPos - Double(lo))
                let val = Float(src[lo]) * (1.0 - frac) + Float(src[hi]) * frac
                dst[i] = Int16(clamping: Int(val.rounded()))
            }
        }
    }
    return output
}

// MARK: - AudioManager

@MainActor
public final class AudioManager: ObservableObject {

    // MARK: - Published Properties

    @Published public private(set) var inputLevel: Float = 0
    @Published public private(set) var outputLevel: Float = 0
    @Published public private(set) var isCapturing = false
    @Published public private(set) var isPlaying = false

    @Published public var isMuted = false {
        didSet {
            muteState.lock.lock()
            muteState.value = isMuted
            muteState.lock.unlock()
        }
    }

    // MARK: - Callbacks

    public var onAudioCaptured: (@Sendable (Data) -> Void)?
    public var onPlaybackFinished: (@Sendable () -> Void)?

    // MARK: - Configuration

    private var configuredInputRate: Double = 16000
    private var configuredOutputRate: Double = 24000

    public func configure(inputSampleRate: Double, outputSampleRate: Double) {
        self.configuredInputRate = inputSampleRate
        self.configuredOutputRate = outputSampleRate
    }

    // MARK: - Private State

    private var vpioGraph: AUGraph?
    private var vpioBridge: VPIOBridge?
    private let muteState = MuteStateBox()
    private var levelUpdateTimer: Timer?
    private var playbackDrainTicks = 0
    private static let bytesPerSample = 2

    // MARK: - Init

    public init() {}

    // MARK: - Voice Processing

    public func showMicrophoneModePicker() {
        AVCaptureDevice.showSystemUserInterface(.microphoneModes)
    }

    // MARK: - Capture

    public func startCapture(voiceProcessingEnabled: Bool = false) async throws {
        guard !isCapturing else { return }

        let permission = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
        guard permission else { throw AudioError.permissionDenied }

        try setupVPIO()
        isCapturing = true
        startLevelMetering()
        print("[AudioManager] VPIO capture started with AEC at \(configuredOutputRate) Hz")
    }

    public func stopCapture() {
        guard isCapturing else { return }
        teardownVPIO()
        isCapturing = false
        isPlaying = false
        inputLevel = 0
        outputLevel = 0
        stopLevelMetering()
    }

    // MARK: - Playback

    public func queueAudio(_ audioData: Data) {
        guard audioData.count > 0, audioData.count % Self.bytesPerSample == 0 else { return }
        guard let bridge = vpioBridge else { return }
        bridge.writePlayback(audioData)
        playbackDrainTicks = 0
        if !isPlaying { isPlaying = true }
    }

    public func clearPlaybackQueue() {
        vpioBridge?.clearPlayback()
        isPlaying = false
        outputLevel = 0
        playbackDrainTicks = 0
    }

    public func stopPlayback() {
        clearPlaybackQueue()
    }

    /// No-op: VPIO handles echo cancellation natively.
    public func setServerModelSpeaking(_ isSpeaking: Bool) {}

    // MARK: - VPIO Setup

    private func setupVPIO() throws {
        let vpioRate = configuredOutputRate

        let bridge = VPIOBridge(
            muteBox: muteState,
            minSendSize: 640,
            vpioRate: vpioRate,
            targetCaptureRate: configuredInputRate
        )
        bridge.captureCallback = self.onAudioCaptured

        var graph: AUGraph?
        var status = NewAUGraph(&graph)
        guard status == noErr, let graph else { throw AudioError.engineCreationFailed }

        var vpioDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_VoiceProcessingIO,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        var vpioNode: AUNode = 0
        status = AUGraphAddNode(graph, &vpioDesc, &vpioNode)
        guard status == noErr else { throw AudioError.engineCreationFailed }

        status = AUGraphOpen(graph)
        guard status == noErr else { throw AudioError.engineCreationFailed }

        var audioUnit: AudioUnit?
        status = AUGraphNodeInfo(graph, vpioNode, &vpioDesc, &audioUnit)
        guard status == noErr, let audioUnit else { throw AudioError.engineCreationFailed }

        let bus0: AudioUnitElement = 0
        let bus1: AudioUnitElement = 1

        var enableIO: UInt32 = 1
        let ioSize = UInt32(MemoryLayout.size(ofValue: enableIO))

        status = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO,
                                      kAudioUnitScope_Input, bus1, &enableIO, ioSize)
        guard status == noErr else { throw AudioError.engineCreationFailed }

        status = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO,
                                      kAudioUnitScope_Output, bus0, &enableIO, ioSize)
        guard status == noErr else { throw AudioError.engineCreationFailed }

        var streamDesc = AudioStreamBasicDescription(
            mSampleRate: vpioRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        let descSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

        status = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Output, bus1, &streamDesc, descSize)
        guard status == noErr else { throw AudioError.engineCreationFailed }

        status = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Input, bus0, &streamDesc, descSize)
        guard status == noErr else { throw AudioError.engineCreationFailed }

        var bypassVP: UInt32 = 0
        status = AudioUnitSetProperty(audioUnit, kAUVoiceIOProperty_BypassVoiceProcessing,
                                      kAudioUnitScope_Global, 0, &bypassVP,
                                      UInt32(MemoryLayout.size(ofValue: bypassVP)))
        guard status == noErr else { throw AudioError.engineCreationFailed }

        bridge.audioUnit = audioUnit
        self.vpioBridge = bridge

        let refCon = Unmanaged.passUnretained(bridge).toOpaque()

        var inputCB = AURenderCallbackStruct(inputProc: vpioInputCallback, inputProcRefCon: refCon)
        status = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_SetInputCallback,
                                      kAudioUnitScope_Input, bus1, &inputCB,
                                      UInt32(MemoryLayout.size(ofValue: inputCB)))
        guard status == noErr else { throw AudioError.engineCreationFailed }

        var renderCB = AURenderCallbackStruct(inputProc: vpioRenderCallback, inputProcRefCon: refCon)
        status = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_SetRenderCallback,
                                      kAudioUnitScope_Output, bus0, &renderCB,
                                      UInt32(MemoryLayout.size(ofValue: renderCB)))
        guard status == noErr else { throw AudioError.engineCreationFailed }

        status = AUGraphInitialize(graph)
        guard status == noErr else { throw AudioError.engineCreationFailed }

        status = AUGraphStart(graph)
        guard status == noErr else { throw AudioError.engineCreationFailed }

        self.vpioGraph = graph
    }

    private func teardownVPIO() {
        if let graph = vpioGraph {
            AUGraphStop(graph)
            if let au = vpioBridge?.audioUnit {
                AudioUnitUninitialize(au)
            }
            DisposeAUGraph(graph)
        }
        vpioGraph = nil
        vpioBridge?.audioUnit = nil
        vpioBridge = nil
    }

    // MARK: - Level Metering

    private func startLevelMetering() {
        guard let bridge = vpioBridge else { return }

        let onFinished = self.onPlaybackFinished
        levelUpdateTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            let inLevel = bridge.inputLevelBox.read()
            let outLevel = bridge.outputLevelBox.read()
            let pbEmpty = bridge.isPlaybackEmpty

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.inputLevel = max(inLevel, self.inputLevel * 0.82)
                self.outputLevel = outLevel

                if self.isPlaying && pbEmpty {
                    self.playbackDrainTicks += 1
                    if self.playbackDrainTicks >= 3 {
                        self.isPlaying = false
                        self.outputLevel = 0
                        self.playbackDrainTicks = 0
                        onFinished?()
                    }
                } else {
                    self.playbackDrainTicks = 0
                }
            }
        }
    }

    private func stopLevelMetering() {
        levelUpdateTimer?.invalidate()
        levelUpdateTimer = nil
    }
}

// MARK: - Errors

public enum AudioError: LocalizedError {
    case permissionDenied
    case engineCreationFailed
    case inputNodeUnavailable
    case formatCreationFailed
    case converterCreationFailed

    public var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Microphone permission was denied"
        case .engineCreationFailed: return "Failed to create audio engine"
        case .inputNodeUnavailable: return "Audio input is unavailable"
        case .formatCreationFailed: return "Failed to create audio format"
        case .converterCreationFailed: return "Failed to create audio converter"
        }
    }
}
