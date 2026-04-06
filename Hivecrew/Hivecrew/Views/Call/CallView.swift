//
//  CallView.swift
//  Hivecrew
//
//  Root view for the Call tab. Switches between idle, active, and suspended states.
//

import SwiftUI

struct CallView: View {

    @EnvironmentObject var orchestrator: VoiceOrchestrator

    var body: some View {
        Group {
            switch orchestrator.callState {
            case .idle:
                IdleCallView()

            case .active, .idleTimeout, .compactShare:
                ExpandedCallView()

            case .suspended:
                ExpandedCallView()
                    .overlay {
                        VStack {
                            Spacer()
                            VStack(spacing: 12) {
                                HStack(spacing: 8) {
                                    Image(systemName: "moon.zzz.fill")
                                        .font(.title2)
                                        .foregroundStyle(.yellow)
                                    Text("Call paused to save costs")
                                        .font(.subheadline.weight(.medium))
                                }

                                Text("The session will resume when a worker needs attention, or you can wake it manually.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)

                                HStack(spacing: 12) {
                                    Button {
                                        Task { await orchestrator.resumeCall() }
                                    } label: {
                                        Label("Resume", systemImage: "mic.fill")
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.regular)

                                    Button {
                                        orchestrator.endCall()
                                    } label: {
                                        Label("End Call", systemImage: "phone.down.fill")
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(.red)
                                    .controlSize(.regular)
                                }
                            }
                            .padding(20)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                            .padding(.bottom, 20)
                        }
                    }
            }
        }
        .environmentObject(orchestrator)
    }
}
