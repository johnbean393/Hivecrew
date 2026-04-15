//
//  SampleHandler.swift
//  HivelinkBroadcast
//

import CoreMedia
import CoreVideo
import ReplayKit
import UIKit

final class SampleHandler: RPBroadcastSampleHandler {

    private static let appGroupID = "group.com.pattonium.Hivelink"
    private static let frameInterval: CFTimeInterval = 1.0
    private static let jpegQuality: CGFloat = 0.5
    private static let ringBufferSize = 2

    private var broadcastDir: URL?
    private var lastFrameTime: CFTimeInterval = 0
    private var frameIndex: Int = 0
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupID
        ) else { return }

        let dir = container.appendingPathComponent("broadcast", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        broadcastDir = dir
        lastFrameTime = 0
        frameIndex = 0

        writeMeta(active: true)
    }

    override func broadcastPaused() {}

    override func broadcastResumed() {}

    override func broadcastFinished() {
        writeMeta(active: false)
        cleanupFiles()
        broadcastDir = nil
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with type: RPSampleBufferType) {
        guard type == .video, let dir = broadcastDir else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let seconds = CMTimeGetSeconds(pts)
        guard seconds - lastFrameTime >= Self.frameInterval else { return }
        lastFrameTime = seconds

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        guard let cgImage = ciContext.createCGImage(ciImage, from: CGRect(x: 0, y: 0, width: width, height: height)) else { return }

        let uiImage = UIImage(cgImage: cgImage)
        guard let jpegData = uiImage.jpegData(compressionQuality: Self.jpegQuality) else { return }

        let slot = frameIndex % Self.ringBufferSize
        let fileURL = dir.appendingPathComponent("broadcast_frame_\(slot).jpg")
        try? jpegData.write(to: fileURL, options: .atomic)

        frameIndex += 1
        writeMeta(active: true)
    }

    // MARK: - Metadata

    private func writeMeta(active: Bool) {
        guard let dir = broadcastDir else { return }
        let metaURL = dir.appendingPathComponent("broadcast_meta.plist")
        let dict: NSDictionary = [
            "frameIndex": frameIndex,
            "timestamp": Date().timeIntervalSince1970,
            "broadcastActive": active,
        ]
        dict.write(to: metaURL, atomically: true)
    }

    private func cleanupFiles() {
        guard let dir = broadcastDir else { return }
        for slot in 0..<Self.ringBufferSize {
            let fileURL = dir.appendingPathComponent("broadcast_frame_\(slot).jpg")
            try? FileManager.default.removeItem(at: fileURL)
        }
        let metaURL = dir.appendingPathComponent("broadcast_meta.plist")
        try? FileManager.default.removeItem(at: metaURL)
    }
}
