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
#if os(macOS)
import CoreAudio
#endif
import os

// MARK: - VoiceProcessingIO Bridge

/// Shared state accessed by VPIO audio-thread callbacks.
/// All audio-thread access is single-threaded (one callback at a time).
/// Playback buffer uses its own lock for cross-thread writes.
private final class VPIOBridge: @unchecked Sendable {
    var audioUnit: AudioUnit?

    // Capture state (accessed only from input callback thread)
    let muteBox: MuteStateBox
    let echoGate: EchoGateBox
    let inputLevelBox: LevelBox
    let minSendSize: Int
    let vpioRate: Double
    let targetCaptureRate: Double
    var captureAccumulator = Data()
    var captureCallback: (@Sendable (Data) -> Void)?

    // Playback ring buffer (written from main, read from render callback)
    private var pbLock = os_unfair_lock_s()
    private var pbBuffer = Data()
    let outputLevelBox: LevelBox

    init(muteBox: MuteStateBox, echoGate: EchoGateBox, minSendSize: Int, vpioRate: Double, targetCaptureRate: Double) {
        self.muteBox = muteBox
        self.echoGate = echoGate
        self.inputLevelBox = LevelBox()
        self.outputLevelBox = LevelBox()
        self.minSendSize = minSendSize
        self.vpioRate = vpioRate
        self.targetCaptureRate = targetCaptureRate
    }

    func writePlayback(_ data: Data) {
        os_unfair_lock_lock(&pbLock)
        pbBuffer.append(data)
        os_unfair_lock_unlock(&pbLock)
    }

    func readPlayback(count: Int) -> Data {
        os_unfair_lock_lock(&pbLock)
        if pbBuffer.isEmpty {
            os_unfair_lock_unlock(&pbLock)
            return Data(count: count)
        }
        let available = min(count, pbBuffer.count)
        let chunk = Data(pbBuffer.prefix(available))
        pbBuffer.removeFirst(available)
        os_unfair_lock_unlock(&pbLock)
        if available < count {
            return chunk + Data(count: count - available)
        }
        return chunk
    }

    func clearPlayback() {
        os_unfair_lock_lock(&pbLock)
        pbBuffer.removeAll()
        os_unfair_lock_unlock(&pbLock)
    }

    var isPlaybackEmpty: Bool {
        os_unfair_lock_lock(&pbLock)
        defer { os_unfair_lock_unlock(&pbLock) }
        return pbBuffer.isEmpty
    }
}

private final class MuteStateBox: @unchecked Sendable {
    var lock = os_unfair_lock_s()
    var value = false
}

/// Half-duplex echo gate. While the server model is producing audio,
/// the input callback checks the playback buffer: if audio is actively
/// being rendered to the speaker, captured mic data is suppressed.
/// This prevents loudspeaker echo from reaching the server's VAD
/// regardless of volume, while still allowing barge-in during natural
/// pauses between model sentences (when the playback buffer briefly
/// empties).
private final class EchoGateBox: @unchecked Sendable {
    var lock = os_unfair_lock_s()
    var active = false
}

private final class LevelBox: @unchecked Sendable {
    var lock = os_unfair_lock_s()
    var level: Float = 0
    func update(_ v: Float) { os_unfair_lock_lock(&lock); level = v; os_unfair_lock_unlock(&lock) }
    func read() -> Float { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return level }
}

private struct VPIOCleanupState: @unchecked Sendable {
    let graph: AUGraph
    let audioUnit: AudioUnit?
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

    os_unfair_lock_lock(&bridge.muteBox.lock)
    let muted = bridge.muteBox.value
    os_unfair_lock_unlock(&bridge.muteBox.lock)
    if muted { return noErr }

    let mBuf = bufferList.mBuffers
    guard let mData = mBuf.mData, mBuf.mDataByteSize > 0 else { return noErr }

    let byteCount = Int(mBuf.mDataByteSize)

    let currentLevel = levelFromInt16(mData, byteCount: byteCount)
    bridge.inputLevelBox.update(currentLevel)

    os_unfair_lock_lock(&bridge.echoGate.lock)
    let gateActive = bridge.echoGate.active
    os_unfair_lock_unlock(&bridge.echoGate.lock)
    if gateActive && !bridge.isPlaybackEmpty {
        bridge.captureAccumulator.removeAll(keepingCapacity: true)
        return noErr
    }

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

#if os(macOS)
private func audioObjectDataSize(
    objectID: AudioObjectID,
    address: inout AudioObjectPropertyAddress
) -> UInt32? {
    var dataSize: UInt32 = 0
    let status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &dataSize)
    guard status == noErr else { return nil }
    return dataSize
}

private func inputAudioDeviceIDs() -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    guard let dataSize = audioObjectDataSize(objectID: AudioObjectID(kAudioObjectSystemObject), address: &address) else {
        return []
    }

    let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = Array(repeating: AudioDeviceID(), count: count)
    var mutableDataSize = dataSize
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &mutableDataSize,
        &deviceIDs
    )
    guard status == noErr else { return [] }
    return deviceIDs.filter(audioDeviceHasInputStreams)
}

private func audioDeviceHasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )
    guard let dataSize = audioObjectDataSize(objectID: deviceID, address: &address) else {
        return false
    }
    return dataSize > 0
}

private func defaultInputAudioDeviceID() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var deviceID = AudioDeviceID()
    var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &dataSize,
        &deviceID
    )
    guard status == noErr, deviceID != 0 else { return nil }
    return deviceID
}

private func audioDeviceStringProperty(
    _ selector: AudioObjectPropertySelector,
    deviceID: AudioDeviceID
) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var unmanagedValue: Unmanaged<CFString>?
    var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutablePointer(to: &unmanagedValue) { pointer in
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, pointer)
    }
    guard status == noErr, let value = unmanagedValue?.takeUnretainedValue() else { return nil }
    return value as String
}

private func audioDeviceTransportType(_ deviceID: AudioDeviceID) -> UInt32? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyTransportType,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var transportType: UInt32 = 0
    var dataSize = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &transportType)
    guard status == noErr else { return nil }
    return transportType
}

private func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
    inputAudioDeviceIDs().first { deviceID in
        audioDeviceStringProperty(kAudioDevicePropertyDeviceUID, deviceID: deviceID) == uid
    }
}

private func microphoneModeDisplayName(_ mode: AVCaptureDevice.MicrophoneMode) -> String {
    switch mode {
    case .standard:
        return "Standard"
    case .voiceIsolation:
        return "Voice Isolation"
    case .wideSpectrum:
        return "Wide Spectrum"
    @unknown default:
        return "Unknown"
    }
}
#endif

public struct AudioInputDevice: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case builtIn
        case external
        case aggregate
        case virtual
        case unknown
    }

    public let id: String
    public let name: String
    public let kind: Kind
    public let isDefault: Bool
}

// MARK: - AudioManager

@MainActor
public final class AudioManager: ObservableObject {

    // MARK: - Published Properties

    @Published public private(set) var inputLevel: Float = 0
    @Published public private(set) var outputLevel: Float = 0
    @Published public private(set) var isCapturing = false
    @Published public private(set) var isPlaying = false
    @Published public private(set) var availableInputDevices: [AudioInputDevice] = []
    @Published public private(set) var activeInputDeviceID: String?
    @Published public private(set) var activeInputDeviceName: String = "System Default"
    @Published public private(set) var activeMicrophoneModeName: String = "Standard"
    @Published public private(set) var preferredMicrophoneModeName: String = "Standard"

    @Published public var isMuted = false {
        didSet {
            os_unfair_lock_lock(&muteState.lock)
            muteState.value = isMuted
            os_unfair_lock_unlock(&muteState.lock)
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
    private let echoGateState = EchoGateBox()
    private var levelUpdateTimer: Timer?
    private var playbackDrainTicks = 0
    private static let bytesPerSample = 2
    private var preferredInputDeviceID: String?
    private var lastVoiceProcessingEnabled = false
    /// True when the system's hardware echo cancellation
    /// (`setPrefersEchoCancelledInput`) is active, so VPIO's own voice
    /// processing should be bypassed to avoid double AEC.
    private var usingSystemEchoCancellation = false

    // MARK: - Init

    public init() {
        refreshInputDevices()
    }

    // MARK: - Voice Processing

    public func showMicrophoneModePicker() {
        #if os(macOS)
        AVCaptureDevice.showSystemUserInterface(.microphoneModes)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshInputDevices()
        }
        #endif
    }

    public func refreshInputDevices() {
        #if os(macOS)
        let currentDeviceID = currentInputAudioDeviceID()
        let defaultDeviceID = defaultInputAudioDeviceID()

        availableInputDevices = inputAudioDeviceIDs()
            .compactMap { deviceID in
                guard let uid = audioDeviceStringProperty(kAudioDevicePropertyDeviceUID, deviceID: deviceID),
                      let name = audioDeviceStringProperty(kAudioObjectPropertyName, deviceID: deviceID) else {
                    return nil
                }

                return AudioInputDevice(
                    id: uid,
                    name: name,
                    kind: inputDeviceKind(for: audioDeviceTransportType(deviceID)),
                    isDefault: deviceID == defaultDeviceID
                )
            }
            .sorted { lhs, rhs in
                if lhs.isDefault != rhs.isDefault {
                    return lhs.isDefault && !rhs.isDefault
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }

        if let currentDeviceID,
           let currentUID = audioDeviceStringProperty(kAudioDevicePropertyDeviceUID, deviceID: currentDeviceID) {
            activeInputDeviceID = currentUID
            activeInputDeviceName = availableInputDevices.first(where: { $0.id == currentUID })?.name ?? "System Default"
        } else {
            activeInputDeviceID = nil
            activeInputDeviceName = "System Default"
        }

        preferredMicrophoneModeName = microphoneModeDisplayName(AVCaptureDevice.preferredMicrophoneMode)
        activeMicrophoneModeName = microphoneModeDisplayName(AVCaptureDevice.activeMicrophoneMode)
        #else
        activeInputDeviceID = nil
        activeInputDeviceName = "Default"
        #endif
    }

    public func setPreferredInputDevice(_ deviceID: String?) {
        preferredInputDeviceID = normalizedDeviceID(deviceID)
        refreshInputDevices()
    }

    public func selectInputDevice(_ deviceID: String?) async throws {
        preferredInputDeviceID = normalizedDeviceID(deviceID)
        refreshInputDevices()

        guard isCapturing else { return }
        stopCapture()
        try await startCapture(voiceProcessingEnabled: lastVoiceProcessingEnabled)
    }

    public func inputDevice(matching deviceID: String?) -> AudioInputDevice? {
        guard let normalized = normalizedDeviceID(deviceID) else { return nil }
        return availableInputDevices.first(where: { $0.id == normalized })
    }

    static func recommendedPreset(for deviceKind: AudioInputDevice.Kind?) -> VoiceSessionConfig.AudioPolicy.Preset {
        switch deviceKind {
        case .builtIn:
            return .noisyRoom
        case .external, .aggregate, .virtual, .unknown, .none:
            return .balanced
        }
    }

    public func recommendedPreset(for deviceID: String?) -> VoiceSessionConfig.AudioPolicy.Preset {
        let candidateDevice = inputDevice(matching: deviceID)
            ?? inputDevice(matching: activeInputDeviceID)
        return Self.recommendedPreset(for: candidateDevice?.kind)
    }

    // MARK: - Capture

    /// Configure the audio session category and request microphone permission
    /// without activating the session or starting the VPIO graph. Call this
    /// before CallKit reports the outgoing call so the session category is
    /// ready when CallKit activates the audio session.
    public func prepareAudioSession() async throws {
        let permission = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
        guard permission else { throw AudioError.permissionDenied }

        #if os(iOS)
        try configureAudioSessionCategory()
        #endif
    }

    public func startCapture(voiceProcessingEnabled: Bool = false) async throws {
        guard !isCapturing else { return }
        lastVoiceProcessingEnabled = voiceProcessingEnabled

        let permission = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
        guard permission else { throw AudioError.permissionDenied }

        #if os(iOS)
        try configureAudioSessionCategory()
        try AVAudioSession.sharedInstance().setActive(true)
        #endif

        try setupVPIO()
        isCapturing = true
        startLevelMetering()
        refreshInputDevices()
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
        refreshInputDevices()
    }

    #if os(iOS)
    /// Sets the audio session category, mode, and echo-cancellation
    /// preference. On iPhone models running iOS 18.2+ with hardware echo
    /// cancellation support, uses `.default` mode with
    /// `setPrefersEchoCancelledInput(true)`. Otherwise falls back to
    /// `.voiceChat` mode which lets VPIO handle AEC.
    private func configureAudioSessionCategory() throws {
        let session = AVAudioSession.sharedInstance()
        let options: AVAudioSession.CategoryOptions = [
            .defaultToSpeaker,
            .allowBluetooth,
            .allowBluetoothA2DP,
            .duckOthers,
        ]

        if #available(iOS 18.2, *), session.isEchoCancelledInputAvailable {
            try session.setCategory(.playAndRecord, mode: .default, options: options)
            try session.setPrefersEchoCancelledInput(true)
            usingSystemEchoCancellation = true
            print("[AudioManager] Using system hardware echo cancellation")
        } else {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
            usingSystemEchoCancellation = false
        }
    }
    #endif

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

    /// Activate or deactivate the echo gate. While active, captured audio
    /// below the barge-in threshold is suppressed so residual echo from the
    /// loudspeaker doesn't trigger the server's voice-activity detector.
    public func setServerModelSpeaking(_ isSpeaking: Bool) {
        os_unfair_lock_lock(&echoGateState.lock)
        echoGateState.active = isSpeaking
        os_unfair_lock_unlock(&echoGateState.lock)
    }

    private func normalizedDeviceID(_ deviceID: String?) -> String? {
        let trimmed = (deviceID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    #if os(macOS)
    private func inputDeviceKind(for transportType: UInt32?) -> AudioInputDevice.Kind {
        guard let transportType else { return .unknown }
        switch transportType {
        case UInt32(kAudioDeviceTransportTypeBuiltIn):
            return .builtIn
        case UInt32(kAudioDeviceTransportTypeAggregate):
            return .aggregate
        case UInt32(kAudioDeviceTransportTypeVirtual):
            return .virtual
        case UInt32(kAudioDeviceTransportTypeUSB),
             UInt32(kAudioDeviceTransportTypeBluetooth),
             UInt32(kAudioDeviceTransportTypeBluetoothLE),
             UInt32(kAudioDeviceTransportTypeDisplayPort),
             UInt32(kAudioDeviceTransportTypeHDMI),
             UInt32(kAudioDeviceTransportTypeAirPlay):
            return .external
        default:
            return .external
        }
    }

    private func currentInputAudioDeviceID() -> AudioDeviceID? {
        if let audioUnit = vpioBridge?.audioUnit {
            var deviceID = AudioDeviceID()
            var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
            let status = AudioUnitGetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                &dataSize
            )
            if status == noErr, deviceID != 0 {
                return deviceID
            }
        }

        return defaultInputAudioDeviceID()
    }

    private func applyPreferredInputDevice(to audioUnit: AudioUnit) {
        guard let preferredInputDeviceID,
              let deviceID = audioDeviceID(forUID: preferredInputDeviceID) else {
            return
        }

        var mutableDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        if status != noErr {
            print("[AudioManager] Failed to select preferred input device: \(status)")
        }
    }
    #endif

    // MARK: - VPIO Setup

    private func setupVPIO() throws {
        let vpioRate = configuredOutputRate

        let bridge = VPIOBridge(
            muteBox: muteState,
            echoGate: echoGateState,
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

        var bypassVP: UInt32 = usingSystemEchoCancellation ? 1 : 0
        status = AudioUnitSetProperty(audioUnit, kAUVoiceIOProperty_BypassVoiceProcessing,
                                      kAudioUnitScope_Global, 0, &bypassVP,
                                      UInt32(MemoryLayout.size(ofValue: bypassVP)))
        guard status == noErr else { throw AudioError.engineCreationFailed }

        #if os(macOS)
        applyPreferredInputDevice(to: audioUnit)
        #endif

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
        let graph = vpioGraph
        let audioUnit = vpioBridge?.audioUnit
        let bridge = vpioBridge

        vpioGraph = nil
        vpioBridge?.audioUnit = nil
        vpioBridge = nil

        if let graph {
            let cleanupState = VPIOCleanupState(graph: graph, audioUnit: audioUnit)
            DispatchQueue.global(qos: .default).async {
                AUGraphStop(cleanupState.graph)
                if let au = cleanupState.audioUnit {
                    AudioUnitUninitialize(au)
                }
                DisposeAUGraph(cleanupState.graph)
                withExtendedLifetime(bridge) {}
            }
        }
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
