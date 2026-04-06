//
//  CallControlButton.swift
//  Hivecrew
//
//  Reusable circular control button, recycled from Genie's button styling.
//  On macOS 26+ uses .glassEffect(); on macOS 15 uses a gradient + shadow fallback.
//

import SwiftUI

struct CallControlButton: View {

    let icon: String
    let color: Color
    var size: CGFloat = 48
    var iconSize: CGFloat = 20
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            buttonContent
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var buttonContent: some View {
        if #available(macOS 26, *) {
            ZStack {
                Circle()
                    .fill(color)
                    .frame(width: size, height: size)

                Image(systemName: icon)
                    .font(.system(size: iconSize, weight: .medium))
                    .foregroundColor(.white)
            }
            .glassEffect()
        } else {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                color.opacity(0.9),
                                color,
                                color.mix(with: .black, by: 0.25)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: size, height: size)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
                    )
                    .shadow(color: color.opacity(0.4), radius: 6, y: 3)
                    .shadow(color: .black.opacity(0.2), radius: 2, y: 1)

                Image(systemName: icon)
                    .font(.system(size: iconSize, weight: .medium))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
            }
        }
    }
}
