//
//  RunningTaskDetailView.swift
//  Hivelink
//

import HivecrewAPIModels
import HivecrewCore
import SwiftData
import SwiftUI

struct RunningTaskDetailView: View {
    let task: TaskRecord

    @EnvironmentObject private var taskService: HivelinkTaskService
    @EnvironmentObject private var peerConnectionManager: PeerConnectionManager

    @State private var showInstructionSheet = false
    @State private var instructionText = ""
    @State private var answerText = ""
    @State private var answeredIds: Set<String> = []
    @State private var showFullScreenshot = false
    @State private var isUserScrolledUp = false

    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height

            VStack(spacing: 0) {
                if isLandscape {
                    HStack(spacing: 0) {
                        screenshotPane(expandToFillHeight: true)
                            .frame(width: geometry.size.width * 0.46)

                        Divider()

                        detailPane
                    }
                } else {
                    VStack(spacing: 0) {
                        screenshotPane(expandToFillHeight: false)
                        detailPane
                    }
                }
            }
        }
        .background(Color(.systemGroupedBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                todoProgressBar
                actionBar
            }
        }
        .task {
            await taskService.ensureMonitoring(for: task)
        }
        .sheet(isPresented: $showInstructionSheet) {
            instructionSheet
        }
        .fullScreenCover(isPresented: $showFullScreenshot) {
            fullScreenScreenshotView
        }
    }

    // MARK: - Screenshot

    @ViewBuilder
    private func screenshotPane(expandToFillHeight: Bool) -> some View {
        screenshotSection(expandToFillHeight: expandToFillHeight)
            .frame(maxWidth: .infinity, maxHeight: expandToFillHeight ? .infinity : nil)
    }

    private var detailPane: some View {
        VStack(spacing: 0) {
            headerSection
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)

            Divider()

            activityStream
        }
    }

    @ViewBuilder
    private func screenshotSection(expandToFillHeight: Bool) -> some View {
        let screenshot = peerConnectionManager.screenshot(for: task.id)

        if let image = screenshot {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: expandToFillHeight ? .infinity : nil)
                .background(Color.black)
                .id(image)
                .transition(.opacity)
                .onTapGesture { showFullScreenshot = true }
                .animation(.easeInOut(duration: 0.3), value: screenshot != nil)
        } else {
            screenshotPlaceholder(expandToFillHeight: expandToFillHeight)
        }
    }

    private func screenshotPlaceholder(expandToFillHeight: Bool) -> some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            Text("Waiting for screenshot…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: expandToFillHeight ? .infinity : nil)
        .frame(height: expandToFillHeight ? nil : 180)
        .background(Color(.secondarySystemBackground))
    }

    // MARK: - Full-screen screenshot

    private var fullScreenScreenshotView: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image = peerConnectionManager.screenshot(for: task.id) {
                    ScrollView([.horizontal, .vertical], showsIndicators: false) {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: UIScreen.main.bounds.width * 2)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showFullScreenshot = false } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.white)
                    }
                }
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: statusIconName)
                    .font(.title2)
                    .foregroundStyle(statusColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(task.status.displayName)
                        .font(.headline)
                    if let peer = task.clusterPeerName, !peer.isEmpty {
                        Text("on \(peer)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    elapsedTime

                    let stepCount = peerConnectionManager.events(for: task.id)
                        .filter { $0.type == .toolCallStart }.count
                    if stepCount > 0 {
                        Text("\(stepCount) steps")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            modelPill
        }
    }

    private var modelPill: some View {
        HStack(spacing: 6) {
            let providerName = taskService.getProviderName(for: task.providerId)
            Text(providerName)
                .font(.caption2.weight(.medium))
            Text("·")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(task.modelId)
                .font(.caption2)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
    }

    private var elapsedTime: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Text(formattedElapsed)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var formattedElapsed: String {
        let start = task.startedAt ?? task.createdAt
        let elapsed = Int(Date().timeIntervalSince(start))
        let hours = elapsed / 3600
        let minutes = (elapsed % 3600) / 60
        let seconds = elapsed % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var statusIconName: String {
        switch task.status {
        case .running: return "arrow.trianglehead.2.counterclockwise.rotate.90"
        case .planning: return "brain"
        case .paused: return "pause.circle.fill"
        case .waitingForVM: return "clock.fill"
        default: return "circle.fill"
        }
    }

    private var statusColor: Color {
        switch task.status {
        case .running:
            return Color(red: 0.0, green: 0.48, blue: 1.0)
        case .planning:
            return Color(red: 0.58, green: 0.32, blue: 0.95)
        case .paused, .waitingForVM:
            return Color(red: 1.0, green: 0.82, blue: 0.0)
        default:
            return Color(.tertiaryLabel)
        }
    }

    // MARK: - Alert banner

    @ViewBuilder
    private var alertBanner: some View {
        if let question = peerConnectionManager.pendingQuestion(for: task.id),
           !answeredIds.contains(question.id) {
            questionBanner(question: question)
                .transition(.move(edge: .top).combined(with: .opacity))
        } else {
            let events = peerConnectionManager.events(for: task.id)
            if let permEvent = events.last(where: { $0.type == .permissionRequest }),
               let permId = permEvent.data["id"]?.stringValue,
               !answeredIds.contains(permId) {
                permissionBanner(event: permEvent, permissionId: permId)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private func questionBanner(question: APIAgentQuestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundStyle(.orange)
                Text("Agent Question")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.orange)
            }

            Text(question.question)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)

            if let suggestions = question.suggestedAnswers, !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button(suggestion) {
                                submitAnswer(questionId: question.id, answer: suggestion)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("Type an answer…", text: $answerText)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.send)
                    .onSubmit {
                        guard !answerText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        submitAnswer(questionId: question.id, answer: answerText)
                    }

                Button {
                    guard !answerText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    submitAnswer(questionId: question.id, answer: answerText)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title3)
                }
                .disabled(answerText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func permissionBanner(event: APITaskEvent, permissionId: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.blue)
                Text("Permission Request")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.blue)
            }

            if let toolName = event.data["tool_name"]?.stringValue {
                Text(toolName)
                    .font(.subheadline.weight(.medium))
            }

            Text(event.data["details"]?.stringValue ?? "The agent wants to perform an action.")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button {
                    submitPermission(permissionId: permissionId, approved: true)
                } label: {
                    Label("Approve", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button(role: .destructive) {
                    submitPermission(permissionId: permissionId, approved: false)
                } label: {
                    Label("Deny", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(14)
        .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.blue.opacity(0.3), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Activity stream

    private var activityStream: some View {
        let events = peerConnectionManager.events(for: task.id)

        return ZStack(alignment: .bottom) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        alertBanner

                        ForEach(Array(events.enumerated()), id: \.offset) { index, event in
                            TraceEventRow(event: event)
                                .id(index)
                            if index < events.count - 1 {
                                Divider().padding(.leading, 44)
                            }
                        }

                        Color.clear
                            .frame(height: 96)
                            .id("bottom")
                            .onAppear { isUserScrolledUp = false }
                            .onDisappear { isUserScrolledUp = true }
                    }
                }
                .onChange(of: events.count) { _, _ in
                    if !isUserScrolledUp {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
            }

            if isUserScrolledUp && !events.isEmpty {
                jumpToLatestPill
            }
        }
    }

    private var jumpToLatestPill: some View {
        Button {
            isUserScrolledUp = false
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down")
                    .font(.caption2.weight(.semibold))
                Text("Jump to latest")
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Todo progress

    private var todoProgress: (completed: Int, total: Int, currentLabel: String?)? {
        guard let plan = task.planMarkdown, !plan.isEmpty else { return nil }

        let checkboxPattern = #"^\s*-\s*\[([ xX])\]\s*(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: checkboxPattern, options: .anchorsMatchLines) else {
            return nil
        }
        let lines = plan.components(separatedBy: .newlines)
        var items: [(label: String, preCompleted: Bool)] = []
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            if let match = regex.firstMatch(in: line, range: range),
               let stateRange = Range(match.range(at: 1), in: line),
               let contentRange = Range(match.range(at: 2), in: line) {
                let state = String(line[stateRange])
                let content = String(line[contentRange]).trimmingCharacters(in: .whitespaces)
                items.append((content, state.lowercased() == "x"))
            }
        }
        guard !items.isEmpty else { return nil }

        let events = peerConnectionManager.events(for: task.id)
        let finishCount = events.filter { event in
            guard event.type == .toolCallResult else { return false }
            let summary = event.data["summary"]?.stringValue ?? ""
            let toolName = event.data["tool_name"]?.stringValue ?? ""
            return toolName.contains("finish_todo") || summary.contains("Plan item completed")
                || summary.contains("todo") && summary.contains("completed")
        }.count

        let preCompleted = items.filter(\.preCompleted).count
        let completed = min(preCompleted + finishCount, items.count)
        let currentLabel: String? = completed < items.count ? items[completed].label : nil
        return (completed, items.count, currentLabel)
    }

    @ViewBuilder
    private var todoProgressBar: some View {
        if let progress = todoProgress, progress.total > 0 {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 3)
                        Circle()
                            .trim(from: 0, to: Double(progress.completed) / Double(progress.total))
                            .stroke(Color.green, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(progress.completed)/\(progress.total)")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                    .frame(width: 32, height: 32)

                    if let label = progress.currentLabel {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Current step")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } else {
                        Text("All plan items completed")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.regularMaterial)
            }
        }
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack(spacing: 12) {
            switch task.status {
            case .running:
                Button {
                    Task { await taskService.pauseTask(task) }
                } label: {
                    Label("Pause", systemImage: "pause.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    showInstructionSheet = true
                } label: {
                    Label("Instruct", systemImage: "text.bubble")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Spacer()

                Button(role: .destructive) {
                    Task { await taskService.cancelTask(task) }
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .controlSize(.small)

            case .paused:
                Button {
                    Task { await taskService.resumeTask(task) }
                } label: {
                    Label("Resume", systemImage: "play.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Spacer()

                Button(role: .destructive) {
                    Task { await taskService.cancelTask(task) }
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .controlSize(.small)

            default:
                Spacer()

                Button(role: .destructive) {
                    Task { await taskService.cancelTask(task) }
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    // MARK: - Instruction sheet

    private var instructionSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Send an instruction to the agent…", text: $instructionText, axis: .vertical)
                        .lineLimit(3...8)
                }
            }
            .navigationTitle("Send Instruction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showInstructionSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        let text = instructionText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        Task {
                            await taskService.sendInstruction(text, to: task)
                            instructionText = ""
                            showInstructionSheet = false
                        }
                    }
                    .disabled(instructionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Actions

    private func submitAnswer(questionId: String, answer: String) {
        withAnimation { answeredIds.insert(questionId) }
        answerText = ""
        Task {
            await taskService.answerQuestion(task, questionId: questionId, answer: answer)
        }
    }

    private func submitPermission(permissionId: String, approved: Bool) {
        withAnimation { answeredIds.insert(permissionId) }
        Task {
            await taskService.respondToPermission(task, permissionId: permissionId, approved: approved)
        }
    }
}

#Preview {
    RunningTaskDetailView(task: TaskRecord(
        id: "preview-1",
        title: "Build the landing page",
        taskDescription: "Create a responsive landing page with hero section",
        status: .running,
        providerId: "cluster-remote:Anthropic",
        modelId: "claude-sonnet-4-20250514"
    ))
    .environmentObject(HivelinkTaskService(
        modelContext: {
            let container = try! ModelContainer(for: TaskRecord.self)
            return ModelContext(container)
        }(),
        clusterCoordinator: HivelinkClusterCoordinator(),
        remoteTaskIndex: RemoteTaskIndex()
    ))
    .environmentObject(PeerConnectionManager(
        remoteTaskIndex: RemoteTaskIndex(),
        clusterCoordinator: HivelinkClusterCoordinator()
    ))
}
