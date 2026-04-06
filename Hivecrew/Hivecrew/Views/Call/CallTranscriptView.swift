//
//  CallTranscriptView.swift
//  Hivecrew
//
//  Scrolling transcript view with gradient fade mask.
//  Extends Genie's TranscriptionView with alternating user/model turns.
//

import SwiftUI

struct CallTranscriptView: View {

    let entries: [TranscriptEntry]
    var assistantName: String = "Hivecrew"

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(entries) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Text(entry.role == .user ? "You" : assistantName)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(entry.role == .user ? .blue : .secondary)
                                    .frame(width: 64, alignment: .trailing)

                                Text(entry.text)
                                    .font(.system(size: 14))
                                    .foregroundColor(.primary)
                                    .textSelection(.enabled)
                            }
                            .id(entry.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(width: geo.size.width, alignment: .leading)
                    .frame(minHeight: geo.size.height)
                }
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.1),
                            .init(color: .black, location: 0.9),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .onChange(of: entries.count) {
                    if let last = entries.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }
}
