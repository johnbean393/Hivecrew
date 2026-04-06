//
//  VideoSourceManager.swift
//  HivecrewVoice
//
//  Unified manager for screen and camera video sources.
//  Only one source active at a time; switching deactivates the previous.
//

import Foundation
import ScreenCaptureKit
import AVFoundation
import Combine

@MainActor
public final class VideoSourceManager: ObservableObject {

    @Published public private(set) var activeSource: VideoSource = .none
    @Published public private(set) var availableScreens: [SCDisplay] = []
    @Published public private(set) var availableCameras: [AVCaptureDevice] = []

    public let screenCapture = ScreenCaptureManager()
    public let cameraCapture = CameraCaptureManager()

    private var cameraSink: AnyCancellable?

    /// Unified callback: fires whenever the active source produces a frame.
    public var onFrameCaptured: ((Data) -> Void)?

    public init() {
        screenCapture.onFrameCaptured = { [weak self] data in
            self?.onFrameCaptured?(data)
        }
        cameraCapture.onFrameCaptured = { [weak self] data in
            self?.onFrameCaptured?(data)
        }
        cameraCapture.onCaptureInvalidated = { [weak self] in
            guard let self else { return }
            if case .camera = self.activeSource {
                self.activeSource = .none
            }
        }
        cameraSink = cameraCapture.$availableCameras
            .receive(on: DispatchQueue.main)
            .sink { [weak self] devices in
                self?.availableCameras = devices
            }
    }

    // MARK: - Source Enumeration

    public func refreshSources() async {
        if let displays = try? await screenCapture.getAvailableDisplays() {
            availableScreens = displays
        }
        cameraCapture.refreshAvailableCameras()
        availableCameras = cameraCapture.availableCameras
    }

    // MARK: - Activation

    public func activate(source: VideoSource) async {
        guard source != activeSource else { return }
        await deactivate()

        switch source {
        case .none:
            break
        case .screen(let displayID):
            if let displays = try? await screenCapture.getAvailableDisplays(),
               let display = displays.first(where: { $0.displayID == displayID }) {
                await screenCapture.startSharing(display: display)
                activeSource = .screen(displayID: displayID)
            }
        case .camera(let deviceID):
            try? await cameraCapture.startCapture(deviceID: deviceID)
            if cameraCapture.isCapturing {
                activeSource = .camera(deviceID: deviceID)
            }
        }
    }

    public func deactivate() async {
        switch activeSource {
        case .screen:
            await screenCapture.stopSharing()
        case .camera:
            cameraCapture.stopCapture()
        case .none:
            break
        }
        activeSource = .none
    }

    /// Capture the current frame from whichever source is active.
    public func captureCurrentFrame() async -> Data? {
        switch activeSource {
        case .screen(let displayID):
            if let displays = try? await screenCapture.getAvailableDisplays(),
               let display = displays.first(where: { $0.displayID == displayID }) {
                return await screenCapture.captureStillFrame(display: display)
            }
            return nil
        case .camera:
            return cameraCapture.captureStillFrame()
        case .none:
            return nil
        }
    }
}
