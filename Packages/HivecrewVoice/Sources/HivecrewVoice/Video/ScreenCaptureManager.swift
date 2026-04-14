//
//  ScreenCaptureManager.swift
//  HivecrewVoice
//
//  ScreenCaptureKit-based screen capture at ~1 FPS JPEG.
//  Ported from Genie with own-app window exclusion.
//

import Foundation
@preconcurrency import ScreenCaptureKit
import CoreGraphics
import AppKit

@MainActor
public class ScreenCaptureManager: NSObject, ObservableObject {

    @Published public private(set) var isSharing = false
    @Published public var error: String?

    private var stream: SCStream?
    private var streamOutput: CaptureOutput?

    public var onFrameCaptured: ((Data) -> Void)?

    private let captureTimeBox = CaptureTimeBox()
    let minimumFrameInterval: TimeInterval = 1.0

    public override init() { super.init() }

    private final class CaptureTimeBox: @unchecked Sendable {
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

    // MARK: - Public API

    public func getAvailableDisplays() async throws -> [SCDisplay] {
        let content = try await SCShareableContent.current
        return content.displays
    }

    public func getDisplayPreview(for display: SCDisplay) async -> NSImage? {
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()

        let maxDim = 960.0
        let ar = Double(display.width) / Double(display.height)
        var w: Int, h: Int
        if display.width >= display.height {
            w = Int(maxDim); h = Int(maxDim / ar)
        } else {
            h = Int(maxDim); w = Int(maxDim * ar)
        }
        config.width = w & ~1
        config.height = h & ~1
        config.showsCursor = false

        do {
            let cg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        } catch {
            return nil
        }
    }

    public func startSharing(display: SCDisplay? = nil) async {
        do {
            let content = try await SCShareableContent.current
            let selected = display ?? content.displays.first
            guard let selected else {
                error = "No display found"; return
            }

            let excludedApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            let filter = SCContentFilter(display: selected, excludingApplications: excludedApps, exceptingWindows: [])

            let config = SCStreamConfiguration()
            let maxDim = 1920.0
            let ar = Double(selected.width) / Double(selected.height)
            var w: Int, h: Int
            if selected.width >= selected.height {
                w = Int(maxDim); h = Int(maxDim / ar)
            } else {
                h = Int(maxDim); w = Int(maxDim * ar)
            }
            config.width = w & ~1
            config.height = h & ~1
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.queueDepth = 5

            streamOutput = CaptureOutput(parent: self)
            stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream?.addStreamOutput(streamOutput!, type: .screen, sampleHandlerQueue: .global(qos: .userInitiated))
            try await stream?.startCapture()

            isSharing = true
            error = nil
        } catch {
            self.error = error.localizedDescription
            isSharing = false
        }
    }

    public func stopSharing() async {
        if let stream { try? await stream.stopCapture() }
        stream = nil
        streamOutput = nil
        isSharing = false
    }

    public func captureStillFrame(display: SCDisplay) async -> Data? {
        let excludedApps: [SCRunningApplication]
        if let content = try? await SCShareableContent.current {
            excludedApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        } else {
            excludedApps = []
        }

        let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = display.width & ~1
        config.height = display.height & ~1
        config.showsCursor = false

        guard let cg = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return nil }
        return Self.encodeJPEG(from: cg, quality: 0.85)
    }

    // MARK: - JPEG Encoding (nonisolated for use from capture callbacks)

    nonisolated static func encodeJPEG(from cgImage: CGImage, quality: Double = 0.6) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    // MARK: - Stream Output

    private class CaptureOutput: NSObject, SCStreamOutput {
        weak var parent: ScreenCaptureManager?

        init(parent: ScreenCaptureManager) { self.parent = parent }

        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .screen, let parent else { return }
            guard parent.captureTimeBox.elapsed() >= parent.minimumFrameInterval else { return }

            guard let imageBuffer = sampleBuffer.imageBuffer else { return }
            let ciImage = CIImage(cvImageBuffer: imageBuffer)
            let context = CIContext()
            guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }

            guard let jpegData = ScreenCaptureManager.encodeJPEG(from: cgImage) else { return }

            parent.captureTimeBox.update()
            Task { @MainActor in
                parent.onFrameCaptured?(jpegData)
            }
        }
    }
}
