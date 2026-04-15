//
//  InputSourcePickerView.swift
//  Hivelink
//
//  Video source picker shown as a sheet. Lists available camera sources.
//  Also provides the CameraPreviewPip UIViewRepresentable used by the orb.
//

import AVFoundation
import HivecrewVoice
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
