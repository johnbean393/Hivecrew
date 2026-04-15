//
//  iOSScreenBroadcastReceiver.swift
//  Hivelink
//
//  Monitors the App Group container for JPEG frames written by the
//  HivelinkBroadcast ReplayKit extension and forwards them to the
//  voice provider's video pipeline.
//

import Combine
import Foundation

@MainActor
final class iOSScreenBroadcastReceiver: ObservableObject {

    private static let appGroupID = "group.com.pattonium.Hivelink"
    private static let pollInterval: TimeInterval = 1.0
    private static let ringBufferSize = 2

    @Published private(set) var isReceiving = false

    var onFrameReceived: ((Data) -> Void)?

    private var pollTimer: Timer?
    private var lastFrameIndex: Int = -1
    private var broadcastDir: URL?

    func startMonitoring() {
        guard !isReceiving else { return }
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupID
        ) else { return }

        broadcastDir = container.appendingPathComponent("broadcast", isDirectory: true)
        lastFrameIndex = -1
        isReceiving = true

        pollTimer = Timer.scheduledTimer(
            withTimeInterval: Self.pollInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollForNewFrame()
            }
        }
    }

    func stopMonitoring() {
        pollTimer?.invalidate()
        pollTimer = nil
        isReceiving = false
        lastFrameIndex = -1
    }

    private func pollForNewFrame() {
        guard let dir = broadcastDir else { return }

        let metaURL = dir.appendingPathComponent("broadcast_meta.plist")
        guard let meta = NSDictionary(contentsOf: metaURL) else {
            return
        }

        guard let active = meta["broadcastActive"] as? Bool, active else {
            stopMonitoring()
            return
        }

        guard let frameIndex = meta["frameIndex"] as? Int,
              frameIndex > lastFrameIndex else { return }

        let slot = (frameIndex - 1) % Self.ringBufferSize
        let frameURL = dir.appendingPathComponent("broadcast_frame_\(slot).jpg")

        guard let data = try? Data(contentsOf: frameURL) else { return }

        lastFrameIndex = frameIndex
        onFrameReceived?(data)
    }
}
