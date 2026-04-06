//
//  ExpandedCallView.swift
//  Hivecrew
//
//  Two-pane layout for an active call: conversation on the left, tasks on the right.
//

import SwiftUI

struct ExpandedCallView: View {

    @EnvironmentObject var orchestrator: VoiceOrchestrator

    var body: some View {
        HSplitView {
            CallConversationPane()
                .environmentObject(orchestrator)
                .frame(minWidth: 320, idealWidth: 400)

            CallTaskPane()
                .environmentObject(orchestrator)
                .frame(minWidth: 280, idealWidth: 400)
        }
    }
}
