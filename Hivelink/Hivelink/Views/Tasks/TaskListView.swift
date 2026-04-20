//
//  TaskListView.swift
//  Hivelink
//

import HivecrewCore
import SwiftData
import SwiftUI

struct TaskListView: View {
    @Binding var tabSelection: Int

    @EnvironmentObject private var taskService: HivelinkTaskService

    @State private var searchText = ""
    @State private var isSearchActive = false
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isSearchActive.toggle()
                        if !isSearchActive { searchText = "" }
                    }
                } label: {
                    Image(systemName: isSearchActive ? "xmark" : "magnifyingglass")
                        .imageScale(.medium)
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            PromptBar(tabSelection: $tabSelection)
                .padding(.vertical, 6)
        }
        .alert(String(localized: "Couldn't create task"), isPresented: Binding(
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

    @FocusState private var searchFieldFocused: Bool

    private var listContent: some View {
        List {
            if isSearchActive {
                Section {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField(String(localized: "Search tasks"), text: $searchText)
                            .textFieldStyle(.plain)
                            .focused($searchFieldFocused)
                            .submitLabel(.search)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
                .onAppear { searchFieldFocused = true }
            }

            if filteredTasks.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No matching tasks",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("Try a different search.")
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
                            if allowsDelete(for: task) {
                                Button(role: .destructive) {
                                    taskService.deleteTask(task)
                                } label: {
                                    Label(String(localized: "Delete"), systemImage: "trash")
                                }
                            }
                            if allowsCancel(for: task) {
                                Button(role: .destructive) {
                                    Task { await taskService.cancelTask(task) }
                                } label: {
                                    Label(String(localized: "Cancel"), systemImage: "xmark.circle")
                                }
                                .tint(.orange)
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            if !task.status.isActive {
                                Button {
                                    rerunTask(task)
                                } label: {
                                    Label(String(localized: "Rerun"), systemImage: "arrow.counterclockwise")
                                }
                                .tint(.blue)

                                Button {
                                    editAndRerunTask(task)
                                } label: {
                                    Label(String(localized: "Edit"), systemImage: "pencil.and.list.clipboard")
                                }
                                .tint(.purple)

                                Button {
                                    continueTask(task)
                                } label: {
                                    Label(String(localized: "Continue"), systemImage: "arrow.turn.down.right")
                                }
                                .tint(.indigo)
                            }
                        }
                        .contextMenu {
                            if !task.status.isActive {
                                Button {
                                    rerunTask(task)
                                } label: {
                                    Label(String(localized: "Rerun"), systemImage: "arrow.counterclockwise")
                                }

                                Button {
                                    editAndRerunTask(task)
                                } label: {
                                    Label(String(localized: "Edit"), systemImage: "pencil.and.list.clipboard")
                                }

                                Button {
                                    continueTask(task)
                                } label: {
                                    Label(String(localized: "Continue"), systemImage: "arrow.turn.down.right")
                                }
                            }

                            Button {
                                UIPasteboard.general.string = task.taskDescription
                            } label: {
                                Label(String(localized: "Copy Description"), systemImage: "doc.on.doc")
                            }

                            if allowsCancel(for: task) {
                                Divider()
                                Button(role: .destructive) {
                                    Task { await taskService.cancelTask(task) }
                                } label: {
                                    Label(String(localized: "Cancel"), systemImage: "xmark.circle")
                                }
                            }

                            if allowsDelete(for: task) {
                                Divider()
                                Button(role: .destructive) {
                                    taskService.deleteTask(task)
                                } label: {
                                    Label(String(localized: "Delete"), systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.interactively)
        .navigationDestination(for: String.self) { taskId in
            TaskDetailView(taskId: taskId)
        }
        .refreshable {
            await taskService.reconcileAndRefresh()
        }
    }

    private var emptyStateNoTasks: some View {
        ContentUnavailableView {
            Label(String(localized: "No tasks yet"), systemImage: "list.bullet.rectangle")
        } description: {
            Text("Create a task with the bar above, or pull to refresh once you're online.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .refreshable {
            await taskService.reconcileAndRefresh()
        }
    }

    private var filteredTasks: [TaskRecord] {
        guard !searchText.isEmpty else { return taskService.tasks }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return taskService.tasks }
        return taskService.tasks.filter { task in
            task.title.localizedCaseInsensitiveContains(q)
                || task.taskDescription.localizedCaseInsensitiveContains(q)
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
        case .completed, .failed, .cancelled, .timedOut, .maxIterations, .planFailed, .queued:
            return true
        case .waitingForVM, .running, .paused, .planning, .planReview, .writebackReview:
            return false
        }
    }

    private func rerunTask(_ task: TaskRecord) {
        let request = TaskCreationRequest(
            description: task.taskDescription,
            providerId: task.providerId,
            modelId: task.modelId,
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

    private func editAndRerunTask(_ task: TaskRecord) {
        NotificationCenter.default.post(
            name: .loadTaskIntoPromptBar,
            object: nil,
            userInfo: ["taskId": task.id]
        )
    }

    private func continueTask(_ task: TaskRecord) {
        NotificationCenter.default.post(
            name: .continueFromTask,
            object: nil,
            userInfo: ["taskId": task.id]
        )
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

// MARK: - Notification Names

extension Notification.Name {
    static let continueFromTask = Notification.Name("continueFromTask")
    static let loadTaskIntoPromptBar = Notification.Name("loadTaskIntoPromptBar")
}

#Preview {
    NavigationStack {
        TaskListView(tabSelection: .constant(0))
    }
    .environmentObject(HivelinkTaskService(modelContext: ModelContext(try! ModelContainer(for: TaskRecord.self)), clusterCoordinator: HivelinkClusterCoordinator(), remoteTaskIndex: RemoteTaskIndex()))
    .environmentObject(HivelinkClusterCoordinator())
    .environmentObject(PeerConnectionManager(
        remoteTaskIndex: RemoteTaskIndex(),
        clusterCoordinator: HivelinkClusterCoordinator()
    ))
}
