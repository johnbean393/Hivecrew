//
//  InputSourcePickerView.swift
//  Hivelink
//
//  Video source picker shown as a sheet. Lists available camera sources.
//  Also provides the CameraPreviewPip UIViewRepresentable used by the orb.
//

import AVFoundation
import HivecrewVoice
import ReplayKit
import SwiftUI

struct InputSourcePickerView: View {
    @EnvironmentObject private var orchestrator: HivelinkVoiceOrchestrator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        Task {
                            await orchestrator.setInputSource(.none)
                            dismiss()
                        }
                    } label: {
                        HStack {
                            Label("Audio Only", systemImage: "mic.fill")
                                .foregroundStyle(.primary)
                            Spacer()
                            if orchestrator.activeInputSource == .none {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                                    .fontWeight(.semibold)
                            }
                        }
                    }
                }

                if orchestrator.supportsVideoInput {
                    Section("Camera") {
                        Button {
                            Task {
                                await orchestrator.setInputSource(.camera)
                                dismiss()
                            }
                        } label: {
                            HStack {
                                Label("Rear Camera", systemImage: "camera.fill")
                                    .foregroundStyle(.primary)
                                Spacer()
                                if orchestrator.activeInputSource == .camera {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                        .fontWeight(.semibold)
                                }
                            }
                        }
                    }

                    Section("Screen Broadcast") {
                        Button {
                            Task {
                                await orchestrator.setInputSource(.screenBroadcast)
                            }
                            BroadcastPickerTrigger.shared.trigger()
                        } label: {
                            HStack {
                                Label("Share Screen", systemImage: "rectangle.inset.filled.and.person.filled")
                                    .foregroundStyle(.primary)
                                Spacer()
                                if orchestrator.activeInputSource == .screenBroadcast {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                        .fontWeight(.semibold)
                                }
                            }
                        }
                        .onAppear {
                            BroadcastPickerTrigger.shared.ensureInstalled(
                                in: UIApplication.shared.connectedScenes
                                    .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                                    .first
                            )
                        }
                    }
                }
            }
            .navigationTitle("Video Source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Broadcast Picker

/// Holds a hidden `RPSystemBroadcastPickerView` off-screen and exposes a
/// method to programmatically trigger its internal button. This lets us
/// present a normal SwiftUI row while still invoking the system broadcast dialog.
final class BroadcastPickerTrigger {
    static let shared = BroadcastPickerTrigger()

    private let picker: RPSystemBroadcastPickerView = {
        let p = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        p.preferredExtension = "com.pattonium.Hivelink.HivelinkBroadcast"
        p.showsMicrophoneButton = false
        p.isHidden = true
        return p
    }()

    private weak var installedIn: UIView?

    func ensureInstalled(in window: UIWindow?) {
        guard let window, installedIn !== window else { return }
        window.addSubview(picker)
        installedIn = window
    }

    func trigger() {
        for subview in picker.subviews {
            if let button = subview as? UIButton {
                button.sendActions(for: .touchUpInside)
                return
            }
        }
    }
}

// MARK: - Camera Preview

struct CameraPreviewPip: UIViewRepresentable {
    let session: AVCaptureSession?

    func makeUIView(context: Context) -> CameraPreviewUIView {
        CameraPreviewUIView()
    }

    func updateUIView(_ view: CameraPreviewUIView, context: Context) {
        view.setSession(session)
    }
}

final class CameraPreviewUIView: UIView {
    private let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        previewLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(previewLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
    }

    func setSession(_ session: AVCaptureSession?) {
        guard previewLayer.session !== session else { return }
        previewLayer.session = session
    }
}

#Preview {
    InputSourcePickerView()
        .environmentObject(HivelinkVoiceOrchestrator())
}
