//
//  VoiceOrbView.swift
//  Hivelink
//
//  Glass-shell liquid orb ported from the macOS Hivecrew app.
//  When a camera session is provided the liquid core is replaced by
//  a live preview and the orb morphs into a rounded square.
//

import AVFoundation
import SwiftUI

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

    private var activeLevel: CGFloat { CGFloat(inputLevel) }
    private var isCameraActive: Bool { cameraSession != nil }

    private var effectiveSize: CGFloat {
        isCameraActive ? size * 2.34 : size
    }

    private var cornerRadius: CGFloat {
        isCameraActive ? effectiveSize * 0.15 : effectiveSize / 2
    }

    var body: some View {
        let s = effectiveSize

        ZStack {
            // Glass shell
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.4), .white.opacity(0.1), .white.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 3
                )
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.black.opacity(isConnected ? 0.3 : 0.1))
                )
                .shadow(color: isConnected ? .blue.opacity(0.55) : .black.opacity(0.15),
                        radius: isConnected ? 10 : 5)

            if isCameraActive {
                if let session = cameraSession {
                    CameraPreviewPip(session: session)
                        .frame(width: s * 0.88, height: s * 0.88)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius * 0.75, style: .continuous))
                }
            } else {
                // Liquid core
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
                        .opacity(isConnected ? 0.95 : 0.4)
                        .blur(radius: isConnected ? 5 : 8)
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
                        .opacity(isConnected ? 0.85 : 0.3)
                        .blur(radius: isConnected ? 4 : 6)
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
                        .blur(radius: 3)
                }
                .animation(.spring(response: 0.5, dampingFraction: 0.8), value: isConnected)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: activeLevel)
            }

            // Glass highlights — subtler over camera
            Group {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(RadialGradient(
                        colors: [.white.opacity(0.5), .white.opacity(0.2), .clear],
                        center: .init(x: 0.35, y: 0.25),
                        startRadius: 0,
                        endRadius: s * 0.5
                    ))
                    .opacity(isCameraActive ? 0.12 : 1.0)

                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
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

#Preview {
    VStack(spacing: 40) {
        VoiceOrbView(inputLevel: 0, outputLevel: 0, isConnected: false, isModelSpeaking: false)
        VoiceOrbView(inputLevel: 0.4, outputLevel: 0, isConnected: true, isModelSpeaking: false)
    }
    .padding()
    .background(.black)
}
