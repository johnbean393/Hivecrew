//
//  CameraCaptureManager.swift
//  HivecrewVoice
//
//  AVCaptureSession-based camera capture supporting built-in and Continuity Camera.
//  Throttled to ~1 FPS JPEG for streaming, with explicit high-res still capture.
//

import Foundation
import AVFoundation
import CoreImage
import AppKit

@MainActor
public final class CameraCaptureManager: NSObject, ObservableObject {

    @Published public private(set) var isCapturing = false
    @Published public private(set) var availableCameras: [AVCaptureDevice] = []
    @Published public private(set) var captureSession: AVCaptureSession?
    @Published public var error: String?

    /// Called when capture stops due to an external event (device disconnected,
    /// session error) rather than an explicit `stopCapture()` call.
    public var onCaptureInvalidated: (() -> Void)?

    private var videoOutput: AVCaptureVideoDataOutput?
    private var currentInput: AVCaptureDeviceInput?
    private let outputQueue = DispatchQueue(label: "com.hivecrew.voice.camera", qos: .userInitiated)
    private var sessionObservers: [Any] = []

    public var onFrameCaptured: ((Data) -> Void)?

    private let lastCaptureBox = LastCaptureBox()
    private let latestFrameBox = LatestFrameBox()
    private let minimumFrameInterval: TimeInterval = 1.0
    private let ciContext = CIContext()

    private final class LastCaptureBox: @unchecked Sendable {
        let lock = NSLock()
        var time: Date = .distantPast
        func elapsed() -> TimeInterval {
            lock.lock(); defer { lock.unlock() }
            return Date().timeIntervalSince(time)
        }
        func update() {
            lock.lock(); defer { lock.unlock() }
            time = Date()
        }
    }

    private final class LatestFrameBox: @unchecked Sendable {
        let lock = NSLock()
        var data: Data?
        func store(_ newData: Data) {
            lock.lock(); data = newData; lock.unlock()
        }
        func read() -> Data? {
            lock.lock(); defer { lock.unlock() }; return data
        }
        func clear() {
            lock.lock(); data = nil; lock.unlock()
        }
    }

    private var deviceObservation: NSKeyValueObservation?
    private var discoverySession: AVCaptureDevice.DiscoverySession?
    private var discoveryObservation: NSKeyValueObservation?

    public override init() {
        super.init()
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        discoverySession = discovery
        availableCameras = discovery.devices

        discoveryObservation = discovery.observe(\.devices, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.refreshAvailableCameras()
            }
        }
    }

    // MARK: - Public API

    public func refreshAvailableCameras() {
        availableCameras = discoverySession?.devices ?? []
    }

    public func startCapture(deviceID: String? = nil) async throws {
        guard !isCapturing else { return }

        let granted = await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .video) { granted in
                cont.resume(returning: granted)
            }
        }
        guard granted else {
            error = "Camera permission denied"
            return
        }

        refreshAvailableCameras()

        let device: AVCaptureDevice?
        if let deviceID {
            device = availableCameras.first(where: { $0.uniqueID == deviceID })
        } else {
            device = availableCameras.first
        }
        guard let device else {
            error = "No camera found"
            return
        }

        let session = AVCaptureSession()
        session.sessionPreset = .medium

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            error = "Cannot add camera input"
            return
        }
        session.addInput(input)
        currentInput = input

        let output = AVCaptureVideoDataOutput()
        output.setSampleBufferDelegate(self, queue: outputQueue)
        output.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(output) else {
            error = "Cannot add video output"
            return
        }
        session.addOutput(output)
        videoOutput = output

        self.captureSession = session
        session.startRunning()
        isCapturing = true
        error = nil

        deviceObservation = device.observe(\.isConnected) { [weak self] device, _ in
            if !device.isConnected {
                Task { @MainActor [weak self] in
                    guard let self, self.isCapturing else { return }
                    self.stopCapture()
                    self.onCaptureInvalidated?()
                }
            }
        }

        let stoppedObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionDidStopRunning,
            object: session,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isCapturing else { return }
                self.stopCapture()
                self.onCaptureInvalidated?()
            }
        }
        sessionObservers.append(stoppedObserver)
    }

    public func stopCapture() {
        sessionObservers.forEach { NotificationCenter.default.removeObserver($0) }
        sessionObservers.removeAll()
        deviceObservation?.invalidate()
        deviceObservation = nil
        captureSession?.stopRunning()
        if let input = currentInput { captureSession?.removeInput(input) }
        captureSession = nil
        videoOutput = nil
        currentInput = nil
        isCapturing = false
        latestFrameBox.clear()
    }

    /// Return the latest JPEG frame captured by the delegate.
    public func captureStillFrame() -> Data? {
        latestFrameBox.read()
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraCaptureManager: AVCaptureVideoDataOutputSampleBufferDelegate {

    nonisolated public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let imageBuffer = sampleBuffer.imageBuffer else { return }
        let ciImage = CIImage(cvImageBuffer: imageBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        guard let jpegData = Self.encodeJPEG(from: cgImage) else { return }

        latestFrameBox.store(jpegData)

        guard lastCaptureBox.elapsed() >= minimumFrameInterval else { return }
        lastCaptureBox.update()
        Task { @MainActor [weak self] in
            self?.onFrameCaptured?(jpegData)
        }
    }

    private nonisolated static func encodeJPEG(from cgImage: CGImage, quality: Double = 0.6) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return data as Data
    }
}
