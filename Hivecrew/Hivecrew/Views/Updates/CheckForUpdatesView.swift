//
//  CheckForUpdatesView.swift
//  Hivecrew
//
//  SwiftUI view that wraps Sparkle's check for updates action
//

import SwiftUI
import Sparkle
import Combine

/// A SwiftUI view that provides a "Check for Updates..." menu item using Sparkle
struct CheckForUpdatesView: View {
    @ObservedObject private var checkForUpdatesViewModel: CheckForUpdatesViewModel
    
    init(updater: SPUUpdater) {
        self.checkForUpdatesViewModel = CheckForUpdatesViewModel(updater: updater)
    }
    
    var body: some View {
        Button(
            "Check for Updates…",
            action: checkForUpdatesViewModel.checkForUpdates
        )
        .disabled(!checkForUpdatesViewModel.canCheckForUpdates)
    }
}

/// View model that observes Sparkle's updater state
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false
    
    private let updater: SPUUpdater
    
    init(updater: SPUUpdater) {
        self.updater = updater
        
        // Observe the updater's canCheckForUpdates property
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
    
    func checkForUpdates() {
        updater.checkForUpdates()
    }
}
