//
//  TaskListView.swift
//  Hivelink
//

import HivecrewCore
import SwiftData
import SwiftUI

enum TaskFilter: String, CaseIterable, Identifiable {
    case all
    case active
    case completed
    case failed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .active: String(localized: "Active")
        case .completed: String(localized: "Completed")
        case .failed: String(localized: "Failed")
        }
    }
}

struct TaskListView: View {
    @Binding var tabSelection: Int

    @EnvironmentObject private var taskService: HivelinkTaskService

    @State private var selectedFilter: TaskFilter = .all
    @State private var searchText = ""
    @State private var sendError: String?

    var body: some View {
        Group {
            if taskService.tasks.isEmpty {
                emptyStateNoTasks
            } else {
                listContent
            }
        }
        .navigationTitle("Hivelink")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, prompt: String(localized: "Search tasks"))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PromptBar(tabSelection: $tabSelection)
        }
        .alert(String(localized: "Couldn’t create task"), isPresented: Binding(
            get: { sendError != nil },
            set: { if !$0 { sendError = nil } }
        )) {
            Button(String(localized: "OK"), role: .cancel) { sendError = nil }
        } message: {
            if let sendError {
                Text(sendError)
            }
        }
    }

    private var listContent: some View {
        List {
            Section {
                filterChipsRow
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            if filteredTasks.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No matching tasks",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("Try a different filter or search.")
                    )
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(filteredTasks) { task in
                        NavigationLink(value: task.id) {
                            TaskRowView(task: task)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if allowsCancel(for: task) {
                                Button(role: .destructive) {
                                    Task { await taskService.cancelTask(task) }
                                } label: {
                                    Label(String(localized: "Cancel"), systemImage: "xmark.circle")
                                }
                                .tint(.orange)
                            }
                            if allowsDelete(for: task) {
                                Button(role: .destructive) {
                                    taskService.deleteTask(task)
                                } label: {
                                    Label(String(localized: "Delete"), systemImage: "trash")
                                }
                            }
                        }
                        .contextMenu {
                            Button {
                                rerunTask(task)
                            } label: {
                                Label(String(localized: "Rerun"), systemImage: "arrow.clockwise")
                            }
                            if allowsDelete(for: task) {
                                Button(role: .destructive) {
                                    taskService.deleteTask(task)
                                } label: {
                                    Label(String(localized: "Delete"), systemImage: "trash")
                                }
                            }
                            Button {
                                UIPasteboard.general.string = task.taskDescription
                            } label: {
                                Label(String(localized: "Copy Description"), systemImage: "doc.on.doc")
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.interactively)
        .navigationDestination(for: String.self) { taskId in
            TaskDetailPlaceholderView(taskId: taskId)
        }
        .refreshable {
            await taskService.reconcileAndRefresh()
        }
    }

    private var emptyStateNoTasks: some View {
        ContentUnavailableView {
            Label(String(localized: "No tasks yet"), systemImage: "list.bullet.rectangle")
        } description: {
            Text("Create a task with the bar below, or pull to refresh once you’re online.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .refreshable {
            await taskService.reconcileAndRefresh()
        }
    }

    private var filterChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(TaskFilter.allCases) { filter in
                    filterChip(filter)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func filterChip(_ filter: TaskFilter) -> some View {
        let selected = selectedFilter == filter
        return Button {
            selectedFilter = filter
        } label: {
            Text(filter.title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    selected
                        ? AnyShapeStyle(.tint.opacity(0.22))
                        : AnyShapeStyle(.quaternary),
                    in: Capsule()
                )
                .overlay(
                    Capsule()
                        .strokeBorder(selected ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private var filteredTasks: [TaskRecord] {
        let searched = taskService.tasks.filter { task in
            guard !searchText.isEmpty else { return true }
            let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if q.isEmpty { return true }
            return task.title.localizedCaseInsensitiveContains(q)
                || task.taskDescription.localizedCaseInsensitiveContains(q)
        }
        return searched.filter { matchesFilter($0, selectedFilter) }
    }

    private func matchesFilter(_ task: TaskRecord, _ filter: TaskFilter) -> Bool {
        switch filter {
        case .all:
            return true
        case .active:
            switch task.status {
            case .queued, .waitingForVM, .running, .planning, .planReview, .paused, .writebackReview:
                return true
            default:
                return false
            }
        case .completed:
            return task.status == .completed && task.wasSuccessful == true
        case .failed:
            if task.status == .completed {
                return task.wasSuccessful != true
            }
            switch task.status {
            case .failed, .cancelled, .timedOut, .maxIterations, .planFailed:
                return true
            default:
                return false
            }
        }
    }

    private func allowsCancel(for task: TaskRecord) -> Bool {
        switch task.status {
        case .completed, .failed, .cancelled, .timedOut, .maxIterations, .planFailed:
            return false
        case .queued, .waitingForVM, .running, .paused, .planning, .planReview, .writebackReview:
            return true
        }
    }

    private func allowsDelete(for task: TaskRecord) -> Bool {
        switch task.status {
        case .completed, .failed, .cancelled, .timedOut, .maxIterations, .planFailed:
            return true
        case .queued, .waitingForVM, .running, .paused, .planning, .planReview, .writebackReview:
            return false
        }
    }

    private func rerunTask(_ task: TaskRecord) {
        let providerId = task.providerId
        let modelId = task.modelId
        let request = TaskCreationRequest(
            description: task.taskDescription,
            providerId: providerId,
            modelId: modelId,
            executionTarget: task.executionTarget,
            reasoningEnabled: task.reasoningEnabled,
            reasoningEffort: task.reasoningEffort,
            serviceTier: task.serviceTier,
            attachedFilePaths: task.attachedFilePaths,
            attachmentInfos: task.attachmentInfos.isEmpty ? nil : task.attachmentInfos,
            mentionedSkillNames: task.mentionedSkillNames ?? [],
            referencedTaskIds: task.referencedTaskIds ?? [],
            continuationSourceTaskId: task.continuationSourceTaskId,
            retrievalContextPackId: task.retrievalContextPackId,
            retrievalInlineContextBlocks: task.retrievalInlineContextBlocks,
            retrievalContextAttachmentPaths: task.retrievalContextAttachmentPaths ?? [],
            retrievalSelectedSuggestionIds: task.retrievalSelectedSuggestionIds ?? [],
            retrievalModeOverrides: task.retrievalModeOverrides,
            clusterReferenceContextBlocks: task.clusterReferenceContextBlocks,
            clusterReferenceFiles: task.clusterReferenceFiles,
            planFirstEnabled: task.planFirstEnabled,
            planMarkdown: task.planMarkdown,
            planSelectedSkillNames: task.planSelectedSkillNames,
            localAccessGrants: task.localAccessGrants,
            clusterOwnerTaskId: nil,
            clusterExecutionAttempt: 0,
            clusterLeaseId: nil
        )
        Task {
            do {
                _ = try await taskService.createTasks([request])
            } catch {
                sendError = error.localizedDescription
            }
        }
    }
}

// MARK: - Detail placeholder

struct TaskDetailPlaceholderView: View {
    let taskId: String

    @EnvironmentObject private var taskService: HivelinkTaskService

    var body: some View {
        Group {
            if let task = taskService.getTask(byId: taskId) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(task.title)
                        .font(.title2.weight(.semibold))
                    Text(task.taskDescription)
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding()
            } else {
                ContentUnavailableView("Task not found", systemImage: "exclamationmark.triangle")
            }
        }
        .navigationTitle(String(localized: "Task"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        TaskListView(tabSelection: .constant(0))
    }
    .environmentObject(HivelinkTaskService(modelContext: ModelContext(try! ModelContainer(for: TaskRecord.self)), clusterCoordinator: HivelinkClusterCoordinator()))
    .environmentObject(HivelinkClusterCoordinator())
}
