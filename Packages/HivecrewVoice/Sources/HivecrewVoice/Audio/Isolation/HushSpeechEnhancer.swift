import Foundation

public enum HushSpeechEnhancerError: Error, Sendable {
    case modelNotFound(String)
    case modelLoadFailed
    case sessionCreateFailed
    case notPrepared
    case libraryNotFound(String)
    case symbolNotFound(String)
}

/// Wraps the Hush (weya-ai/hush) DeepFilterNet3 speech enhancement model
/// via runtime dynamic loading of `libweya_nc.dylib`.
///
/// Hush suppresses background speakers and noise at the waveform level.
/// It operates on 10 ms frames of 16 kHz mono float32 audio.
public actor HushSpeechEnhancer: SpeechEnhancer {

    public struct Metrics: Sendable {
        public var framesProcessed: Int = 0
        public var totalSNRdB: Float = 0
        public var averageSNRdB: Float {
            framesProcessed > 0 ? totalSNRdB / Float(framesProcessed) : 0
        }
    }

    private static let modelSampleRate: Double = 16_000
    private static let modelResourceName = "advanced_dfnet16k_model_best_onnx"
    private static let modelResourceExtension = "tar.gz"
    private static let dylibName = "libweya_nc.dylib"

    private var lib: HushLib?
    private var model: OpaquePointer?
    private var session: OpaquePointer?
    private var frameLength: Int = 0
    private var metrics = Metrics()

    private let attenuationLimitDB: Float

    /// - Parameter attenuationLimitDB: Maximum suppression in dB.
    ///   100.0 means unlimited (strongest suppression).
    public init(attenuationLimitDB: Float = 100.0) {
        self.attenuationLimitDB = attenuationLimitDB
    }

    public func prepare() async throws {
        guard model == nil else { return }

        let loadedLib = try HushLib.load()
        lib = loadedLib

        guard let bundlePath = Bundle.main.path(
            forResource: Self.modelResourceName,
            ofType: Self.modelResourceExtension
        ) else {
            throw HushSpeechEnhancerError.modelNotFound(
                "\(Self.modelResourceName).\(Self.modelResourceExtension) not found in app bundle"
            )
        }

        guard let loadedModel = loadedLib.modelLoadFromPath(bundlePath) else {
            throw HushSpeechEnhancerError.modelLoadFailed
        }
        model = loadedModel

        guard let createdSession = loadedLib.sessionCreate(
            loadedModel,
            Int(Self.modelSampleRate),
            attenuationLimitDB
        ) else {
            loadedLib.modelFree(loadedModel)
            model = nil
            throw HushSpeechEnhancerError.sessionCreateFailed
        }
        session = createdSession
        frameLength = loadedLib.getFrameLength(createdSession)
    }

    public func enhance(_ samples: [Float], sampleRate: Double) async throws -> [Float] {
        guard let lib, let session, frameLength > 0 else {
            throw HushSpeechEnhancerError.notPrepared
        }

        let input: [Float]
        if abs(sampleRate - Self.modelSampleRate) > 0.5 {
            input = PCMUtilities.resampleLinear(samples, from: sampleRate, to: Self.modelSampleRate)
        } else {
            input = samples
        }

        guard !input.isEmpty else { return [] }

        var output = [Float](repeating: 0, count: input.count)
        let fullFrames = input.count / frameLength
        let remainder = input.count % frameLength

        for i in 0..<fullFrames {
            let offset = i * frameLength
            let snr = input.withUnsafeBufferPointer { inBuf in
                output.withUnsafeMutableBufferPointer { outBuf in
                    lib.processFrame(
                        session,
                        inBuf.baseAddress! + offset,
                        outBuf.baseAddress! + offset
                    )
                }
            }
            metrics.framesProcessed += 1
            metrics.totalSNRdB += snr
        }

        if remainder > 0 {
            var paddedFrame = [Float](repeating: 0, count: frameLength)
            let tailOffset = fullFrames * frameLength
            for j in 0..<remainder {
                paddedFrame[j] = input[tailOffset + j]
            }
            var paddedOutput = [Float](repeating: 0, count: frameLength)
            let snr = paddedFrame.withUnsafeBufferPointer { inBuf in
                paddedOutput.withUnsafeMutableBufferPointer { outBuf in
                    lib.processFrame(session, inBuf.baseAddress!, outBuf.baseAddress!)
                }
            }
            metrics.framesProcessed += 1
            metrics.totalSNRdB += snr
            for j in 0..<remainder {
                output[tailOffset + j] = paddedOutput[j]
            }
        }

        if abs(sampleRate - Self.modelSampleRate) > 0.5 {
            return PCMUtilities.resampleLinear(output, from: Self.modelSampleRate, to: sampleRate)
        }
        return output
    }

    public func reset() async {
        if let lib, let session {
            lib.resetSession(session)
        }
    }

    public func shutdown() async {
        if let lib {
            if let session {
                lib.sessionFree(session)
                self.session = nil
            }
            if let model {
                lib.modelFree(model)
                self.model = nil
            }
        }
        frameLength = 0
    }

    public func snapshotMetrics() -> Metrics {
        metrics
    }
}

// MARK: - Dynamic library wrapper

/// Loads `libweya_nc.dylib` at runtime via dlopen, avoiding link-time
/// symbol resolution that would break SPM test builds.
private struct HushLib: @unchecked Sendable {
    typealias ModelLoadFn = @convention(c) (UnsafePointer<CChar>) -> OpaquePointer?
    typealias ModelFreeFn = @convention(c) (OpaquePointer) -> Void
    typealias SessionCreateFn = @convention(c) (OpaquePointer, Int, Float) -> OpaquePointer?
    typealias SessionFreeFn = @convention(c) (OpaquePointer) -> Void
    typealias GetFrameLenFn = @convention(c) (OpaquePointer) -> Int
    typealias ProcessFrameFn = @convention(c) (OpaquePointer, UnsafePointer<Float>, UnsafeMutablePointer<Float>) -> Float
    typealias ResetFn = @convention(c) (OpaquePointer) -> Void

    private let handle: UnsafeMutableRawPointer

    let modelLoadFromPath: ModelLoadFn
    let modelFree: ModelFreeFn
    let sessionCreate: SessionCreateFn
    let sessionFree: SessionFreeFn
    let getFrameLength: GetFrameLenFn
    let processFrame: ProcessFrameFn
    let resetSession: ResetFn

    static func load() throws -> HushLib {
        let searchPaths = [
            Bundle.main.privateFrameworksPath.map { $0 + "/libweya_nc.dylib" },
            Bundle.main.bundlePath + "/Contents/Frameworks/libweya_nc.dylib",
            Bundle.main.bundlePath + "/Contents/MacOS/libweya_nc.dylib",
        ].compactMap { $0 }

        var loaded: UnsafeMutableRawPointer?
        for path in searchPaths {
            loaded = dlopen(path, RTLD_NOW | RTLD_LOCAL)
            if loaded != nil { break }
        }

        if loaded == nil {
            loaded = dlopen("libweya_nc.dylib", RTLD_NOW | RTLD_LOCAL)
        }

        guard let handle = loaded else {
            let err = String(cString: dlerror())
            throw HushSpeechEnhancerError.libraryNotFound(err)
        }

        func sym<T>(_ name: String) throws -> T {
            guard let ptr = dlsym(handle, name) else {
                throw HushSpeechEnhancerError.symbolNotFound(name)
            }
            return unsafeBitCast(ptr, to: T.self)
        }

        return try HushLib(
            handle: handle,
            modelLoadFromPath: sym("weya_nc_model_load_from_path"),
            modelFree: sym("weya_nc_model_free"),
            sessionCreate: sym("weya_nc_session_create"),
            sessionFree: sym("weya_nc_session_free"),
            getFrameLength: sym("weya_nc_get_frame_length"),
            processFrame: sym("weya_nc_process_frame"),
            resetSession: sym("weya_nc_reset")
        )
    }
}
