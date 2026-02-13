//
//  ElapsedTimeView.swift
//  Hivecrew
//
//  Displays elapsed time that updates every second
//

import SwiftUI
import Combine

/// Displays elapsed time that updates every second
struct ElapsedTimeView: View {
    let startDate: Date
    @State private var elapsed: TimeInterval = 0
    
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    var elapsedString: String {
        let seconds = Int(elapsed)
        if seconds < 60 {
            return "\(seconds)s"
        } else if seconds < 3600 {
            return "\(seconds / 60)m \(seconds % 60)s"
        } else {
            let hours = seconds / 3600
            let minutes = (seconds % 3600) / 60
            return "\(hours)h \(minutes)m"
        }
    }
    
    var body: some View {
        Text(elapsedString)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .onReceive(timer) { _ in
                elapsed = Date().timeIntervalSince(startDate)
            }
            .onAppear {
                elapsed = Date().timeIntervalSince(startDate)
            }
    }
}
