import Combine
import SwiftUI

struct RetrievalIndexSidebarView: View {
    @Binding var selection: RetrievalSidebarEntry
    let rows: [RetrievalSidebarRowModel]

    var body: some View {
        List(rows, selection: $selection) { row in
            HStack(spacing: 10) {
                Image(systemName: row.entry.systemImage)
                    .frame(width: 16)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(row.entry.title)
                        .font(.body.weight(.medium))
                    Text(row.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(row.status.title)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(row.status.tint.opacity(0.14), in: Capsule())
                    .foregroundStyle(row.status.tint)
            }
            .padding(.vertical, 2)
            .tag(row.entry)
        }
        .listStyle(.sidebar)
    }
}
