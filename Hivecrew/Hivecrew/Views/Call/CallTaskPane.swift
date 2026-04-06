//
//  CallTaskPane.swift
//  Hivecrew
//
//  Right pane in the active call view showing tasks managed during this session.
//

import SwiftUI

struct CallTaskPane: View {

    @EnvironmentObject var orchestrator: VoiceOrchestrator
    @EnvironmentObject var taskService: TaskService
    @State private var selectedTaskId: String?

    private var sessionTasks: [TaskRecord] {
        taskService.tasks.filter { orchestrator.relevantTaskIds.contains($0.id) }
    }

    private var selectedTask: TaskRecord? {
        guard let id = selectedTaskId else { return nil }
        return sessionTasks.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let task = selectedTask {
                detailHeader(task: task)
                Divider()
                CallTaskDetailView(task: task)
                    .id(task.id)
                    .transition(.move(edge: .trailing))
            } else {
                listContent
                    .transition(.move(edge: .leading))
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipped()
        .animation(.easeInOut(duration: 0.2), value: selectedTaskId)
        .onChange(of: orchestrator.focusedTaskId) { _, newId in
            if let newId, sessionTasks.contains(where: { $0.id == newId }) {
                selectedTaskId = newId
            }
        }
    }

    // MARK: - Detail Header

    private func detailHeader(task: TaskRecord) -> some View {
        HStack {
            Button {
                selectedTaskId = nil
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.caption.weight(.semibold))
                    Text("Workers")
                        .font(.subheadline)
                }
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)

            Spacer()

            Text(task.status.displayName)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - List Content

    @ViewBuilder
    private var listContent: some View {
        if sessionTasks.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "person.3")
                    .font(.largeTitle)
                    .foregroundColor(.secondary.opacity(0.5))
                Text("No workers assigned yet")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text("Describe what you need and workers will appear here")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.7))
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding()
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(sessionTasks) { task in
                        CallTaskRowView(task: task) {
                            selectedTaskId = task.id
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }
}
