import Foundation

public actor VoiceSessionCaptureWriter {
    private let configuration: VoiceSessionCaptureConfiguration
    private let encoder: JSONEncoder
    private let eventHandle: FileHandle
    private let logHandle: FileHandle
    private let rawInputWriter: WAVFileWriter
    private let enhancedWriter: WAVFileWriter?
    private let uplinkWriter: WAVFileWriter
    private let downlinkWriter: WAVFileWriter
    private var finished = false

    public init(configuration: VoiceSessionCaptureConfiguration) throws {
        self.configuration = configuration
        try FileManager.default.createDirectory(
            at: configuration.directoryURL,
            withIntermediateDirectories: true
        )

        let metadataURL = configuration.directoryURL.appendingPathComponent("metadata.json")
        let eventsURL = configuration.directoryURL.appendingPathComponent("events.jsonl")
        let logURL = configuration.directoryURL.appendingPathComponent("session.log")
        let rawInputURL = configuration.directoryURL.appendingPathComponent("input_raw.wav")
        let enhancedURL = configuration.directoryURL.appendingPathComponent("input_enhanced.wav")
        let uplinkURL = configuration.directoryURL.appendingPathComponent("input_uplink.wav")
        let downlinkURL = configuration.directoryURL.appendingPathComponent("output_downlink.wav")

        let metadataEncoder = JSONEncoder()
        metadataEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        metadataEncoder.dateEncodingStrategy = .iso8601
        try metadataEncoder.encode(configuration.metadata).write(to: metadataURL, options: .atomic)

        FileManager.default.createFile(atPath: eventsURL.path, contents: nil)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)

        guard let eventHandle = FileHandle(forWritingAtPath: eventsURL.path),
              let logHandle = FileHandle(forWritingAtPath: logURL.path) else {
            throw CocoaError(.fileWriteUnknown)
        }

        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.eventHandle = eventHandle
        self.logHandle = logHandle
        self.rawInputWriter = try WAVFileWriter(url: rawInputURL, sampleRate: configuration.rawInputSampleRate)
        if let enhancedRate = configuration.enhancedSampleRate {
            self.enhancedWriter = try WAVFileWriter(url: enhancedURL, sampleRate: enhancedRate)
        } else {
            self.enhancedWriter = nil
        }
        self.uplinkWriter = try WAVFileWriter(url: uplinkURL, sampleRate: configuration.uplinkSampleRate)
        self.downlinkWriter = try WAVFileWriter(url: downlinkURL, sampleRate: configuration.downlinkSampleRate)
    }

    public func appendRawInputPCM(_ data: Data) async {
        await rawInputWriter.append(data)
    }

    public func appendEnhancedPCM(_ data: Data) async {
        await enhancedWriter?.append(data)
    }

    public func appendUplinkPCM(_ data: Data) async {
        await uplinkWriter.append(data)
    }

    public func appendDownlinkPCM(_ data: Data) async {
        await downlinkWriter.append(data)
    }

    public func record(_ event: VoiceSessionCaptureEvent) async {
        if let encoded = try? encoder.encode(event) {
            eventHandle.seekToEndOfFile()
            try? eventHandle.write(contentsOf: encoded)
            try? eventHandle.write(contentsOf: Data([0x0A]))
        }

        let line = "\(event.timestamp.ISO8601Format()) [\(event.category.rawValue)] \(event.message)\n"
        if let data = line.data(using: .utf8) {
            logHandle.seekToEndOfFile()
            try? logHandle.write(contentsOf: data)
        }
    }

    public func finish() async {
        guard !finished else { return }
        finished = true
        await rawInputWriter.close()
        await enhancedWriter?.close()
        await uplinkWriter.close()
        await downlinkWriter.close()
        try? eventHandle.synchronizeFile()
        try? eventHandle.close()
        try? logHandle.synchronizeFile()
        try? logHandle.close()
    }
}

private actor WAVFileWriter {
    private let handle: FileHandle
    private let sampleRate: Int
    private var byteCount: UInt32 = 0
    private var closed = false

    init(url: URL, sampleRate: Int) throws {
        self.sampleRate = sampleRate
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: url.path) else {
            throw CocoaError(.fileWriteUnknown)
        }
        self.handle = handle
        try handle.write(contentsOf: Self.makeHeader(sampleRate: sampleRate, dataByteCount: 0))
        try handle.synchronize()
    }

    func append(_ data: Data) {
        guard !data.isEmpty, !closed else { return }
        handle.seekToEndOfFile()
        do {
            try handle.write(contentsOf: data)
            byteCount += UInt32(data.count)
        } catch {}
    }

    func close() {
        guard !closed else { return }
        closed = true
        do {
            handle.seek(toFileOffset: 0)
            try handle.write(contentsOf: Self.makeHeader(sampleRate: sampleRate, dataByteCount: byteCount))
            try handle.synchronize()
            try handle.close()
        } catch {}
    }

    private static func makeHeader(sampleRate: Int, dataByteCount: UInt32) -> Data {
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let riffChunkSize = 36 + dataByteCount

        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        data.append(contentsOf: withUnsafeBytes(of: riffChunkSize.littleEndian, Array.init))
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: channels.littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian, Array.init))
        data.append("data".data(using: .ascii)!)
        data.append(contentsOf: withUnsafeBytes(of: dataByteCount.littleEndian, Array.init))
        return data
    }
}
