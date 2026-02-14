import Combine
import SwiftUI
import AppKit

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
            viewModel.reloadAllowlistRoots()
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
                allowlistRoots: viewModel.allowlistRoots,
                lastRefreshAt: viewModel.lastRefreshAt,
                onAddFolder: addFolderToIndexing,
                onRemoveFolder: { path in
                    Task { _ = await viewModel.removeAllowlistRoot(path: path) }
                },
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

    private func addFolderToIndexing() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Add Folder"
        panel.message = "Choose a folder to include in retrieval indexing."
        guard panel.runModal() == .OK, let folderURL = panel.url else {
            return
        }
        Task {
            _ = await viewModel.addAllowlistRoot(path: folderURL.path)
        }
    }
}
