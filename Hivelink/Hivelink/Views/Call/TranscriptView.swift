//
//  TranscriptView.swift
//  Hivelink
//
//  Scrollable chat-bubble transcript for voice calls.
//

import SwiftUI

struct TranscriptView: View {
    let entries: [TranscriptEntry]

    private var scrollAnchorId: String { "transcript-bottom" }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(entries) { entry in
                        TranscriptBubble(entry: entry)
                            .id(entry.id)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(scrollAnchorId)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .onChange(of: entries.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: entries.last?.text) { _, _ in
                scrollToBottom(proxy)
            }
            .onAppear {
                scrollToBottom(proxy)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(scrollAnchorId, anchor: .bottom)
        }
    }
}

// MARK: - Bubble

private struct TranscriptBubble: View {
    let entry: TranscriptEntry

    var body: some View {
        switch entry.role {
        case .user:
            userBubble
        case .model:
            modelBubble
        case .tool:
            toolPill
        }
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 60)
            Text(entry.text)
                .font(.body)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.blue, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var modelBubble: some View {
        HStack {
            Text(entry.text)
                .font(.body)
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    Color(.systemGray5),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
            Spacer(minLength: 60)
        }
    }

    private var toolPill: some View {
        HStack {
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "wrench.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(entry.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                Color(.systemGray6),
                in: Capsule()
            )
            Spacer()
        }
    }
}

#Preview {
    TranscriptView(entries: [
        .speech(role: .user, text: "Create a landing page for my app"),
        .speech(role: .model, text: "On it — I've assigned Alex to build a landing page for your app."),
        .toolUse(ToolUseRecord(
            toolName: "create_task",
            summary: "Assigned Alex — Landing Page",
            detail: "Task created",
            fileResults: []
        )),
        .speech(role: .user, text: "How's it going?"),
        .speech(role: .model, text: "Alex is about halfway done — they've finished the hero section and navigation."),
    ])
}
