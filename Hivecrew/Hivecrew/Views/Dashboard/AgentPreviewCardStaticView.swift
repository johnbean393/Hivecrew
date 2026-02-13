//
//  AgentPreviewCardStaticView.swift
//  Hivecrew
//
//  Static preview card for tasks without live state publisher
//

import SwiftUI

struct AgentPreviewCardStatic: View {
    let task: TaskRecord
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let previewHeight: CGFloat
    
    var body: some View {
        AgentPreviewCardContent(
            task: task,
            statePublisher: nil,
            cardWidth: cardWidth,
            cardHeight: cardHeight,
            previewHeight: previewHeight,
            previewScreenshot: nil,
            previewScreenshotPath: nil
        )
    }
}
