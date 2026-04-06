//
//  CapturePreviewView.swift
//  Hivecrew
//
//  Thumbnails of captured reference frames with confirm/remove actions.
//

import SwiftUI

struct CapturePreviewView: View {

    @Binding var capturedFramePaths: [String]
    var onConfirm: () -> Void
    var onRemove: (Int) -> Void

    private let columns = [GridItem(.adaptive(minimum: 120))]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Captured References")
                    .font(.headline)
                Spacer()
                Text("\(capturedFramePaths.count) frame(s)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(Array(capturedFramePaths.enumerated()), id: \.offset) { index, path in
                        ZStack(alignment: .topTrailing) {
                            if let image = NSImage(contentsOfFile: path) {
                                Image(nsImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 120, height: 80)
                                    .clipped()
                                    .cornerRadius(8)
                            } else {
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.1))
                                    .frame(width: 120, height: 80)
                                    .cornerRadius(8)
                                    .overlay {
                                        Image(systemName: "photo")
                                            .foregroundColor(.secondary)
                                    }
                            }

                            Button {
                                onRemove(index)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.white)
                                    .background(Color.black.opacity(0.6), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .padding(4)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Confirm") {
                    onConfirm()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 400, height: 300)
    }
}
