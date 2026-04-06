//
//  CallControlBar.swift
//  Hivecrew
//
//  Bottom control bar for the active call: Mic, Video Source, Capture, End Call.
//

import SwiftUI
import HivecrewVoice

struct CallControlBar: View {

    @EnvironmentObject var orchestrator: VoiceOrchestrator
    @State private var showSourcePicker = false
    @State private var showSettingsPopover = false

    private var videoActive: Bool {
        orchestrator.videoSourceManager.activeSource != .none
    }

    var body: some View {
        HStack(spacing: 20) {
            // Mic toggle
            CallControlButton(
                icon: orchestrator.isMuted ? "mic.slash.fill" : "mic.fill",
                color: .black
            ) {
                orchestrator.isMuted.toggle()
            }

            // Video source toggle
            CallControlButton(
                icon: videoActive ? "rectangle.on.rectangle.fill" : "rectangle.dashed.badge.record",
                color: videoActive ? .blue : .black
            ) {
                showSourcePicker.toggle()
            }
            .popover(isPresented: $showSourcePicker) {
                InputSourcePickerView()
                    .environmentObject(orchestrator)
                    .frame(width: 320, height: 300)
            }

            // Capture (visible when video active)
            if videoActive {
                CallControlButton(
                    icon: "camera.fill",
                    color: .black
                ) {
                    Task {
                        if let data = await orchestrator.videoSourceManager.captureCurrentFrame() {
                            let url = FileManager.default.temporaryDirectory.appendingPathComponent("capture_\(UUID().uuidString).jpg")
                            try? data.write(to: url)
                        }
                    }
                }
            }

            // Settings
            CallControlButton(
                icon: "slider.horizontal.3",
                color: .black
            ) {
                showSettingsPopover.toggle()
            }
            .popover(isPresented: $showSettingsPopover) {
                VoiceSettingsPopover()
                    .environmentObject(orchestrator)
            }

            // End call
            CallControlButton(
                icon: "xmark",
                color: Color(red: 0.96, green: 0.26, blue: 0.21)
            ) {
                orchestrator.endCall()
            }
        }
        .padding(.vertical, 12)
    }
}
