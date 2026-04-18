//
//  CallConversationPane.swift
//  Hivecrew
//
//  Left pane of the active call: orb, status, transcript, controls.
//

import SwiftUI
internal import AVFoundation
import HivecrewCore
import HivecrewVoice

struct CallConversationPane: View {

    @EnvironmentObject var orchestrator: VoiceOrchestrator

    private var statusText: String {
        switch orchestrator.connectionState {
        case .error(let msg): return String(localized: "Error: \(msg)")
        case .connecting: return String(localized: "Connecting...")
        case .reconnecting: return String(localized: "Reconnecting...")
        case .connected:
            if orchestrator.callState == .suspended {
                return String(localized: "Paused")
            }
            return orchestrator.isModelSpeaking ? String(localized: "Speaking") : String(localized: "Listening")
        case .disconnected:
            return orchestrator.callState == .suspended ? String(localized: "Paused") : String(localized: "Disconnected")
        }
    }

    private var activeCameraSession: AVCaptureSession? {
        if case .camera = orchestrator.videoSourceManager.activeSource {
            return orchestrator.videoSourceManager.cameraCapture.captureSession
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 16) {
            VoiceOrbView(
                inputLevel: orchestrator.inputLevel,
                outputLevel: orchestrator.outputLevel,
                isConnected: orchestrator.connectionState == .connected || orchestrator.connectionState == .reconnecting,
                isModelSpeaking: orchestrator.isModelSpeaking,
                size: 160,
                cameraSession: activeCameraSession
            )

            Text(statusText)
                .font(.caption)
                .foregroundColor(.secondary)

            CallTranscriptView(entries: $orchestrator.transcript, assistantName: orchestrator.voiceName.capitalized)
                .frame(maxHeight: .infinity)

            if let question = orchestrator.activeWorkerQuestions.first {
                VoiceQuestionBanner(question: question)
                    .environmentObject(orchestrator)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Text("Usage: \(orchestrator.totalTokenCount) tokens")
                .font(.caption2)
                .foregroundColor(.secondary)

            CallControlBar()
                .environmentObject(orchestrator)
        }
        .padding()
        .animation(.easeInOut(duration: 0.2), value: orchestrator.activeWorkerQuestions.first?.id)
        .overlay {
            if orchestrator.callState == .suspended {
                VStack {
                    Spacer()
                    VStack(spacing: 12) {
                        HStack(spacing: 8) {
                            Image(systemName: "moon.zzz.fill")
                                .font(.title2)
                                .foregroundStyle(.yellow)
                        Text(String(localized: "Call paused to save costs"))
                            .font(.subheadline.weight(.medium))
                        }

                        Text(String(localized: "The session will resume when a worker needs attention, or you can wake it manually."))
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
}

// MARK: - Voice Question Banner

struct VoiceQuestionBanner: View {

    let question: AgentQuestion
    @EnvironmentObject var orchestrator: VoiceOrchestrator
    @State private var textAnswer = ""

    private var workerName: String {
        orchestrator.workerRegistry.resolve(query: question.taskId)?.displayName ?? String(localized: "Worker")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: question.isIntervention
                      ? "hand.raised.fill"
                      : "questionmark.bubble.fill")
                    .foregroundStyle(question.isIntervention ? .orange : .yellow)
                Text(String(localized: "\(workerName) is asking:"))
                    .font(.caption.bold())
                Spacer()
            }

            Text(question.question)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            answerControls
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.yellow.opacity(0.3), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var answerControls: some View {
        switch question {
        case .text:
            HStack(spacing: 6) {
                TextField("Type answer…", text: $textAnswer)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit { submitText() }

                Button("Send") { submitText() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(textAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

        case .multipleChoice(let mcq):
            FlowLayout(spacing: 6) {
                ForEach(Array(mcq.options.enumerated()), id: \.offset) { _, option in
                    Button(option) {
                        orchestrator.answerWorkerQuestion(question, answer: option)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

        case .intervention(let req):
            VStack(alignment: .leading, spacing: 6) {
                if let service = req.service {
                    Text("Service: \(service)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Button("Cancel") {
                        orchestrator.answerWorkerQuestion(question, answer: "cancelled")
                    }
                    .controlSize(.small)

                    Button("Done") {
                        orchestrator.answerWorkerQuestion(question, answer: "completed")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
    }

    private func submitText() {
        let answer = textAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return }
        orchestrator.answerWorkerQuestion(question, answer: answer)
        textAnswer = ""
    }
}

// MARK: - Flow Layout

/// Simple horizontal flow layout for MCQ option buttons
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
