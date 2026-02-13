import Combine
import SwiftUI

struct RetrievalIndexOverallDetailView: View {
    let model: RetrievalOverallDetailModel
    let sourceRows: [RetrievalSidebarRowModel]
    let fetchError: String?
    let lastRefreshAt: Date?
    let onRefresh: () -> Void
    let onRestartDaemon: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Retrieval Index")
                            .font(.title2.weight(.semibold))
                        Text("High-level indexing state across all sources.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    statusPill(title: model.status.title, color: model.status.tint)
                }

                HStack(spacing: 12) {
                    metricCard(title: "Indexed", value: model.totalIndexedItems.formatted())
                    metricCard(title: "Queued", value: model.totalQueuedItems.formatted())
                    metricCard(title: "In Flight", value: model.totalInFlightItems.formatted())
                    metricCard(title: "Active Sources", value: model.activeSourceCount.formatted())
                }

                GroupBox("Current Activity") {
                    VStack(alignment: .leading, spacing: 6) {
                        activityRow(label: "Operation", value: model.currentOperation)
                        activityRow(label: "Source", value: model.currentOperationSource?.capitalized ?? "None")
                        activityRow(label: "Item", value: model.currentItemPath ?? "None")
                        activityRow(label: "Last Updated", value: formattedTimestamp(lastRefreshAt ?? model.lastUpdatedAt))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }

                GroupBox("Extraction Totals") {
                    HStack(spacing: 12) {
                        metricCard(title: "Indexed (This Run)", value: model.indexedItemsThisRun.formatted())
                        metricCard(title: "Partial", value: model.extractionPartialCount.formatted())
                        metricCard(title: "Failed", value: model.extractionFailedCount.formatted())
                        metricCard(title: "Unsupported", value: model.extractionUnsupportedCount.formatted())
                        metricCard(title: "OCR", value: model.extractionOCRCount.formatted())
                    }
                    .padding(.top, 4)
                }

                GroupBox("Sources") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(sourceRows.filter { $0.entry != .overall }) { row in
                            HStack(spacing: 12) {
                                Image(systemName: row.entry.systemImage)
                                    .foregroundStyle(.secondary)
                                Text(row.entry.title)
                                    .font(.body.weight(.medium))
                                Spacer()
                                Text(row.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                statusPill(title: row.status.title, color: row.status.tint)
                            }
                        }
                    }
                    .padding(.top, 4)
                }

                if let fetchError, !fetchError.isEmpty {
                    GroupBox("Diagnostics") {
                        Text(fetchError)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }

                HStack(spacing: 10) {
                    Button("Refresh") { onRefresh() }
                        .buttonStyle(.borderedProminent)
                    Button("Restart Daemon") { onRestartDaemon() }
                        .buttonStyle(.bordered)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func metricCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func activityRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.callout)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer()
        }
    }

    private func statusPill(title: String, color: Color) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }

    private func formattedTimestamp(_ date: Date?) -> String {
        guard let date else { return "N/A" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
