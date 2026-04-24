//
//  InputSourcePickerView.swift
//  Hivecrew
//
//  Combined display and camera source picker for the Call tab.
//  Merges Genie's DisplayPickerView with camera device selection.
//

import SwiftUI
import ScreenCaptureKit
import HivecrewVoice

struct InputSourcePickerView: View {

    @EnvironmentObject var orchestrator: VoiceOrchestrator
    @State private var displayPreviews: [UInt32: NSImage] = [:]
    @Environment(\.dismiss) private var dismiss

    /// When true, selecting a source also starts the voice call.
    var startCallOnSelection = false

    private let columns = [GridItem(.adaptive(minimum: 130))]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(startCallOnSelection ? "Start with Video Source" : "Input Source")
                .font(.headline)
                .padding(.horizontal)
                .padding(.top, 8)

            if !orchestrator.supportsVideoInput {
                ContentUnavailableView(
                    "Video Unavailable",
                    systemImage: "video.slash",
                    description: Text("The selected voice provider does not support realtime image or video input.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Screens
                        if !orchestrator.videoSourceManager.availableScreens.isEmpty {
                            Text("Displays")
                                .font(.subheadline.bold())
                                .foregroundColor(.secondary)
                                .padding(.horizontal)

                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(orchestrator.videoSourceManager.availableScreens, id: \.displayID) { display in
                                    Button {
                                        selectSource(.screen(displayID: display.displayID))
                                    } label: {
                                        VStack(spacing: 4) {
                                            if let preview = displayPreviews[display.displayID] {
                                                Image(nsImage: preview)
                                                    .resizable()
                                                    .aspectRatio(contentMode: .fit)
                                                    .frame(height: 80)
                                                    .cornerRadius(6)
                                                    .overlay(
                                                        RoundedRectangle(cornerRadius: 6)
                                                            .stroke(isActiveScreen(display) ? Color.blue : Color.secondary.opacity(0.3), lineWidth: isActiveScreen(display) ? 2 : 1)
                                                    )
                                            } else {
                                                Rectangle()
                                                    .fill(Color.secondary.opacity(0.1))
                                                    .frame(height: 80)
                                                    .aspectRatio(1.6, contentMode: .fit)
                                                    .cornerRadius(6)
                                            }
                                            Text("Display \(display.displayID)")
                                                .font(.caption2)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal)
                        }

                        // Cameras
                        if !orchestrator.videoSourceManager.availableCameras.isEmpty {
                            Text("Cameras")
                                .font(.subheadline.bold())
                                .foregroundColor(.secondary)
                                .padding(.horizontal)

                            ForEach(orchestrator.videoSourceManager.availableCameras, id: \.uniqueID) { device in
                                Button {
                                    selectSource(.camera(deviceID: device.uniqueID))
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "camera.fill")
                                            .foregroundColor(isActiveCamera(device) ? .blue : .secondary)
                                        VStack(alignment: .leading) {
                                            Text(device.localizedName)
                                                .font(.system(size: 13))
                                            if device.deviceType == .external || device.deviceType == .continuityCamera {
                                                Text("Continuity Camera")
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                        Spacer()
                                        if isActiveCamera(device) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(.blue)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                    .padding(.horizontal)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        // Stop sharing (only when mid-call, not pre-call)
                        if !startCallOnSelection && orchestrator.videoSourceManager.activeSource != .none {
                            Divider()
                            Button {
                                Task {
                                    await orchestrator.videoSourceManager.deactivate()
                                    dismiss()
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "stop.circle")
                                        .foregroundColor(.red)
                                    Text("Stop sharing")
                                        .font(.system(size: 13))
                                }
                                .padding(.horizontal)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
        .task {
            guard orchestrator.supportsVideoInput else { return }
            await orchestrator.videoSourceManager.refreshSources()
            await loadPreviews()
        }
    }

    private func selectSource(_ source: VideoSource) {
        guard orchestrator.supportsVideoInput else { return }
        Task {
            if startCallOnSelection {
                NotificationCenter.default.post(name: .startVoiceCall, object: nil)
            }
            await orchestrator.videoSourceManager.activate(source: source)
            dismiss()
        }
    }

    private func isActiveScreen(_ display: SCDisplay) -> Bool {
        if case .screen(let id) = orchestrator.videoSourceManager.activeSource {
            return id == display.displayID
        }
        return false
    }

    private func isActiveCamera(_ device: AVCaptureDevice) -> Bool {
        if case .camera(let id) = orchestrator.videoSourceManager.activeSource {
            return id == device.uniqueID
        }
        return false
    }

    private func loadPreviews() async {
        for display in orchestrator.videoSourceManager.availableScreens {
            if let preview = await orchestrator.videoSourceManager.screenCapture.getDisplayPreview(for: display) {
                displayPreviews[display.displayID] = preview
            }
        }
    }
}
