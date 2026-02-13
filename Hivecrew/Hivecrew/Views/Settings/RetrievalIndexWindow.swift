import Combine
import SwiftUI

struct RetrievalIndexWindow: View {
    @AppStorage("retrievalDaemonEnabled") private var retrievalDaemonEnabled = true
    @StateObject private var viewModel = RetrievalIndexViewModel()

    var body: some View {
        NavigationSplitView {
            RetrievalIndexSidebarView(
                selection: $viewModel.selectedEntry,
                rows: viewModel.sidebarRows(enabled: retrievalDaemonEnabled)
            )
            .frame(minWidth: 250)
        } detail: {
            detailView
        }
        .navigationSplitViewStyle(.balanced)
        .task(id: retrievalDaemonEnabled) {
            viewModel.setPollingEnabled(retrievalDaemonEnabled)
            if retrievalDaemonEnabled {
                await viewModel.refreshNow()
            }
        }
        .onDisappear {
            viewModel.stopPolling()
        }
    }

    @ViewBuilder
    private var detailView: some View {
        if viewModel.selectedEntry == .overall {
            RetrievalIndexOverallDetailView(
                model: viewModel.overallModel(enabled: retrievalDaemonEnabled),
                sourceRows: viewModel.sidebarRows(enabled: retrievalDaemonEnabled),
                fetchError: viewModel.fetchError,
                lastRefreshAt: viewModel.lastRefreshAt,
                onRefresh: { Task { await viewModel.refreshNow() } },
                onRestartDaemon: restartDaemon
            )
        } else {
            RetrievalIndexSourceDetailView(
                model: viewModel.sourceDetail(for: viewModel.selectedEntry, enabled: retrievalDaemonEnabled),
                lastRefreshAt: viewModel.lastRefreshAt,
                onRefresh: { Task { await viewModel.refreshNow() } },
                onRestartDaemon: restartDaemon
            )
        }
    }

    private func restartDaemon() {
        RetrievalDaemonManager.shared.restart()
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            await viewModel.refreshNow()
        }
    }
}
