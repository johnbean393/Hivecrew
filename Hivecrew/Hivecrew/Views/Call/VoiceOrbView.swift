//
//  VoiceOrbView.swift
//  Hivecrew
//
//  Animated voice orb, recycled from Genie with configurable size.
//  When a camera session is provided, the live preview replaces the
//  liquid core and the orb expands by 80% so the feed is clearly visible.
//

import SwiftUI
internal import AVFoundation

struct VoiceOrbView: View {

    let inputLevel: Float
    let outputLevel: Float
    let isConnected: Bool
    let isModelSpeaking: Bool
    var size: CGFloat = 160
    var cameraSession: AVCaptureSession? = nil

    @State private var rotation1: Double = 0
    @State private var rotation2: Double = 0
    @State private var wobble1: CGFloat = -3
    @State private var wobble2: CGFloat = -3
    @State private var breatheScale: CGFloat = 1.0

    private var activeLevel: CGFloat {
        CGFloat(inputLevel)
    }

    private var isCameraActive: Bool { cameraSession != nil }
    private var effectiveSize: CGFloat { isCameraActive ? size * 1.8 : size }

    var body: some View {
        let s = effectiveSize

        ZStack {
            // Glass shell
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.4), .white.opacity(0.1), .white.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 3
                )
                .background(Circle().fill(Color.black.opacity(isConnected ? 0.3 : 0.1)))
                .shadow(color: isConnected ? .blue.opacity(0.3) : .black.opacity(0.1),
                        radius: isConnected ? 20 : 10)

            if isCameraActive {
                // Camera preview replaces the liquid core
                if let session = cameraSession {
                    CameraPreviewView(session: session)
                        .frame(width: s * 0.88, height: s * 0.88)
                        .clipShape(Circle())
                }
            } else {
                // Liquid core (original animated gradients)
                ZStack {
                    Circle()
                        .fill(AngularGradient(
                            gradient: Gradient(colors: [
                                Color(red: 0.3, green: 0.6, blue: 1.0),
                                Color(red: 0.5, green: 0.4, blue: 0.95),
                                Color(red: 0.2, green: 0.7, blue: 0.9),
                                Color(red: 0.4, green: 0.5, blue: 1.0),
                                Color(red: 0.3, green: 0.6, blue: 1.0)
                            ]),
                            center: .center,
                            startAngle: .degrees(rotation1),
                            endAngle: .degrees(rotation1 + 360)
                        ))
                        .scaleEffect(isConnected ? (0.8 + activeLevel * 0.3) : 0.7)
                        .offset(x: isConnected ? wobble1 : 0, y: isConnected ? wobble2 : 0)
                        .opacity(isConnected ? 0.8 : 0.3)
                        .blur(radius: isConnected ? 10 : 15)
                        .grayscale(isConnected ? 0 : 0.8)

                    Circle()
                        .fill(AngularGradient(
                            gradient: Gradient(colors: [
                                Color(red: 0.2, green: 0.5, blue: 0.95),
                                Color(red: 0.4, green: 0.7, blue: 1.0),
                                Color(red: 0.1, green: 0.4, blue: 0.9),
                                Color(red: 0.3, green: 0.6, blue: 0.98),
                                Color(red: 0.2, green: 0.5, blue: 0.95)
                            ]),
                            center: .center,
                            startAngle: .degrees(rotation2),
                            endAngle: .degrees(rotation2 + 360)
                        ))
                        .scaleEffect(isConnected ? (0.75 + activeLevel * 0.25) : 0.65)
                        .rotationEffect(.degrees(90))
                        .offset(x: isConnected ? -wobble2 : 0, y: isConnected ? -wobble1 : 0)
                        .opacity(isConnected ? 0.7 : 0.2)
                        .blur(radius: isConnected ? 8 : 12)
                        .grayscale(isConnected ? 0 : 0.8)

                    Circle()
                        .fill(RadialGradient(
                            colors: [
                                Color(red: 0.6, green: 0.8, blue: 1.0).opacity(isConnected ? 0.9 : 0.3),
                                Color(red: 0.3, green: 0.6, blue: 1.0).opacity(isConnected ? 0.5 : 0.1),
                                .clear
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: s * 0.45
                        ))
                        .scaleEffect(isConnected ? (0.6 + activeLevel * 0.4) : (0.5 * breatheScale))
                        .blur(radius: 5)
                }
                .animation(.spring(response: 0.5, dampingFraction: 0.8), value: isConnected)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: activeLevel)
            }

            // Glass highlights — subtler over camera so the feed stays visible
            Group {
                Circle()
                    .fill(RadialGradient(
                        colors: [.white.opacity(0.5), .white.opacity(0.2), .clear],
                        center: .init(x: 0.35, y: 0.25),
                        startRadius: 0,
                        endRadius: s * 0.5
                    ))
                    .opacity(isCameraActive ? 0.15 : 1.0)

                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.6), .clear, .white.opacity(0.2)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 2
                    )
                    .scaleEffect(0.96)
            }
        }
        .frame(width: s, height: s)
        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: isCameraActive)
        .onAppear { startAnimations() }
    }

    private func startAnimations() {
        withAnimation(.linear(duration: 10).repeatForever(autoreverses: false)) { rotation1 = 360 }
        withAnimation(.linear(duration: 15).repeatForever(autoreverses: false)) { rotation2 = -360 }
        withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) { breatheScale = 1.1 }
        withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) { wobble1 = 3 }
        withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) { wobble2 = 3 }
    }
}

// MARK: - Camera Preview (AVCaptureVideoPreviewLayer)

private final class CameraPreviewNSView: NSView {
    let previewLayer: AVCaptureVideoPreviewLayer

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer!.addSublayer(previewLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }
}

struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        CameraPreviewNSView(session: session)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let preview = nsView as? CameraPreviewNSView {
            preview.previewLayer.session = session
        }
    }
}
