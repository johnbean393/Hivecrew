//
//  ContentView.swift
//  Hivelink
//

import HivecrewAPIModels
import HivecrewCore
import SwiftData
import SwiftUI

struct ContentView: View {
    @Binding var tabSelection: Int

    @EnvironmentObject private var taskService: HivelinkTaskService
    @EnvironmentObject private var peerConnectionManager: PeerConnectionManager
    @EnvironmentObject private var voiceOrchestrator: HivelinkVoiceOrchestrator

    @State private var presentedQuestion: PendingQuestionContext?
    @State private var lastPresentedQuestionId: String?
    @State private var dismissedQuestionIds: Set<String> = []
    @State private var questionAnswerText = ""

    var body: some View {
        TabView(selection: $tabSelection) {
            NavigationStack {
                TaskListView(tabSelection: $tabSelection)
            }
            .tabItem {
                Label("Tasks", systemImage: "list.bullet")
            }
            .tag(0)

            NavigationStack {
                VoiceCallView()
            }
            .tabItem {
                Label("Call", systemImage: "phone.fill")
            }
            .tag(1)

            NavigationStack {
                ClusterStatusView()
                    .navigationTitle("Cluster")
                    .navigationBarTitleDisplayMode(.large)
            }
            .tabItem {
                Label("Cluster", systemImage: "server.rack")
            }
            .tag(2)

            NavigationStack {
                SettingsView()
                    .navigationTitle("Settings")
                    .navigationBarTitleDisplayMode(.large)
            }
            .tabItem {
                Label("Settings", systemImage: "gear")
            }
            .tag(3)
        }
        .onChange(of: peerConnectionManager.taskPendingQuestions) { _, questions in
            if let context = presentedQuestion,
               questions[context.task.id]?.id != context.question.id {
                presentedQuestion = nil
            }

            let voiceActive = voiceOrchestrator.callState != .idle
            guard presentedQuestion == nil, !voiceActive else { return }
            if let (taskId, question) = questions.first(where: { !dismissedQuestionIds.contains($0.value.id) }),
               let task = taskService.getTask(byId: taskId) {
                presentedQuestion = PendingQuestionContext(task: task, question: question)
                lastPresentedQuestionId = question.id
            }
        }
        .onChange(of: voiceOrchestrator.callState) { _, newState in
            if newState != .idle, presentedQuestion != nil {
                presentedQuestion = nil
            }
        }
        .sheet(item: $presentedQuestion, onDismiss: {
            if let id = lastPresentedQuestionId {
                dismissedQuestionIds.insert(id)
            }
            questionAnswerText = ""
        }) { context in
            AgentQuestionSheet(
                context: context,
                answerText: $questionAnswerText,
                onSubmit: { answer in
                    Task {
                        await taskService.answerQuestion(
                            context.task,
                            questionId: context.question.id,
                            answer: answer
                        )
                    }
                    questionAnswerText = ""
                    presentedQuestion = nil
                }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }
}

// MARK: - Pending Question Context

struct PendingQuestionContext: Identifiable {
    let task: TaskRecord
    let question: APIAgentQuestion

    var id: String { question.id }
}

// MARK: - Agent Question Sheet

private struct AgentQuestionSheet: View {
    let context: PendingQuestionContext
    @Binding var answerText: String
    let onSubmit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var fieldFocused: Bool

    private var taskLabel: String {
        let title = context.task.title
        return title.isEmpty ? context.task.taskDescription : title
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 8) {
                        Image(systemName: "questionmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Agent Question")
                                .font(.headline)
                            Text(taskLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Text(context.question.question)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)

                    if let suggestions = context.question.suggestedAnswers, !suggestions.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(suggestions, id: \.self) { suggestion in
                                Button {
                                    onSubmit(suggestion)
                                } label: {
                                    Text(suggestion)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 10)
                                        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Or type a response:")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            TextField("Your answer…", text: $answerText, axis: .vertical)
                                .lineLimit(1...4)
                                .textFieldStyle(.roundedBorder)
                                .focused($fieldFocused)
                                .submitLabel(.send)
                                .onSubmit {
                                    submitTypedAnswer()
                                }

                            Button {
                                submitTypedAnswer()
                            } label: {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(.tint)
                            }
                            .disabled(answerText.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
                .padding(20)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Dismiss") { dismiss() }
                }
            }
        }
    }

    private func submitTypedAnswer() {
        let trimmed = answerText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed)
    }
}

#Preview {
    ContentView(tabSelection: .constant(0))
        .environmentObject(RemoteAccessAuthManager())
        .environmentObject(HivelinkClusterCoordinator())
        .environmentObject(
            HivelinkTaskService(
                modelContext: ModelContext(try! ModelContainer(for: TaskRecord.self)),
                clusterCoordinator: HivelinkClusterCoordinator(),
                remoteTaskIndex: RemoteTaskIndex()
            )
        )
        .environmentObject(PeerConnectionManager(
            remoteTaskIndex: RemoteTaskIndex(),
            clusterCoordinator: HivelinkClusterCoordinator()
        ))
        .environmentObject(ArtifactImportCoordinator())
        .environmentObject(HivelinkVoiceOrchestrator())
}
