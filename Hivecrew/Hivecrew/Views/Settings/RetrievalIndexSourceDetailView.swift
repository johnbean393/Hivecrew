import SwiftUI

struct RetrievalIndexSourceDetailView: View {
    let model: RetrievalSourceDetailModel
    let allowlistRoots: [RetrievalAllowlistRoot]
    let lastRefreshAt: Date?
    let onAddFolder: () -> Void
    let onRemoveFolder: (String) -> Void
    let onRefresh: () -> Void
    let onRestartDaemon: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.entry.title)
                            .font(.title2.weight(.semibold))
                        Text("Source-level indexing diagnostics and live activity.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    statusPill(title: model.status.title, color: model.status.tint)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Progress")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(formattedProgress(model.progress))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: model.progress)
                        .progressViewStyle(.linear)
                        .tint(model.status.tint)
                }

                HStack(spacing: 12) {
                    metricCard(title: "Indexed", value: model.indexedItems.formatted())
                    metricCard(title: "Queued", value: model.queueDepth.formatted())
                    metricCard(title: "In Flight", value: model.inFlightCount.formatted())
                }

                GroupBox("Current Activity") {
                    VStack(alignment: .leading, spacing: 6) {
                        activityRow(label: "Operation", value: model.currentOperation)
                        activityRow(label: "Item", value: model.currentItemPath ?? "None")
                        activityRow(label: "Scopes", value: model.scopeCount.formatted())
                        activityRow(label: "Last Updated", value: formattedTimestamp(lastRefreshAt ?? model.lastUpdatedAt))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }

                if model.entry == .file {
                    GroupBox("File Scan Diagnostics") {
                        HStack(spacing: 12) {
                            metricCard(title: "Candidates Seen", value: model.scanCandidatesSeen.formatted())
                            metricCard(title: "Excluded Skips", value: model.scanCandidatesSkippedExcluded.formatted())
                            metricCard(title: "Events Emitted", value: model.scanEventsEmitted.formatted())
                        }
                        .padding(.top, 4)
                    }

                    GroupBox("Indexed Folders") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(allowlistRoots) { root in
                                HStack(spacing: 10) {
                                    Image(systemName: "folder")
                                        .foregroundStyle(.secondary)
                                    Text(root.path)
                                        .font(.callout)
                                        .textSelection(.enabled)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    if root.isDefault {
                                        Text("Default")
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 4)
                                            .background(Color.secondary.opacity(0.14), in: Capsule())
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Button("Remove") {
                                            onRemoveFolder(root.path)
                                        }
                                        .buttonStyle(.borderless)
                                        .foregroundStyle(.red)
                                    }
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                }

                GroupBox("Extraction Diagnostics") {
                    HStack(spacing: 12) {
                        metricCard(title: "Indexed (This Run)", value: model.cumulativeProcessedCount.formatted())
                        metricCard(title: "Partial", value: model.extractionPartialCount.formatted())
                        metricCard(title: "Failed", value: model.extractionFailedCount.formatted())
                        metricCard(title: "Unsupported", value: model.extractionUnsupportedCount.formatted())
                        metricCard(title: "OCR", value: model.extractionOCRCount.formatted())
                    }
                    .padding(.top, 4)
                }

                HStack(spacing: 10) {
                    if model.entry == .file {
                        Button("Add Folder...") { onAddFolder() }
                            .buttonStyle(.bordered)
                    }
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

    private func formattedProgress(_ value: Double) -> String {
        let clamped = max(0, min(1, value))
        let percentage = clamped * 100
        if percentage < 10 {
            let formatted = percentage.formatted(.number.precision(.fractionLength(1)))
            return "\(formatted)%"
        }
        return "\(Int(percentage.rounded()))%"
    }
}
