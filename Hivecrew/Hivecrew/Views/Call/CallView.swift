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

            case .active, .idleTimeout, .compactShare, .suspended:
                ExpandedCallView()
            }
        }
        .environmentObject(orchestrator)
    }
}
