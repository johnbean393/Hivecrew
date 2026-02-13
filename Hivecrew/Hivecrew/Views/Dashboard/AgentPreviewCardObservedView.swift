//
//  AgentPreviewCardObservedView.swift
//  Hivecrew
//
//  Observed preview card that reacts to live state updates
//

import SwiftUI

struct AgentPreviewCardObserved: View {
    let task: TaskRecord
    @ObservedObject var statePublisher: AgentStatePublisher
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let previewHeight: CGFloat
    @State private var latestScreenshot: NSImage?
    
    var body: some View {
        AgentPreviewCardContent(
            task: task,
            statePublisher: statePublisher,
            cardWidth: cardWidth,
            cardHeight: cardHeight,
            previewHeight: previewHeight,
            previewScreenshot: previewScreenshot,
            previewScreenshotPath: statePublisher.lastScreenshotPath
        )
        .onAppear {
            latestScreenshot = statePublisher.lastScreenshot
        }
        .onReceive(statePublisher.$lastScreenshot) { newScreenshot in
            latestScreenshot = newScreenshot
        }
    }
    
    private var previewScreenshot: NSImage? {
        if let latestScreenshot = latestScreenshot {
            return latestScreenshot
        }
        if let path = statePublisher.lastScreenshotPath {
            return NSImage(contentsOfFile: path)
        }
        return nil
    }
}
