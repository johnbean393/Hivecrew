//
//  PromptBar.swift
//  Hivelink
//

import HivecrewAPIModels
import HivecrewCore
import PhotosUI
import SwiftData
import SwiftUI
import Combine
import UIKit
import UniformTypeIdentifiers

struct PromptBar: View {
    private static let voiceTaskLaunchSnapshotDefaultsKey = "hivelink.voiceTaskLaunchSnapshot"

    private struct VoiceTaskLaunchSnapshot: Codable {
        let providerName: String
        let modelId: String
        let executionTarget: TaskExecutionTarget
        let reasoningEnabled: Bool?
        let reasoningEffort: String?
    }

    @Binding var tabSelection: Int

    @EnvironmentObject private var taskService: HivelinkTaskService
    @EnvironmentObject private var clusterCoordinator: HivelinkClusterCoordinator

    @AppStorage("hivelink.lastProviderName") private var storedProviderName = ""
    @AppStorage("hivelink.lastModelId") private var storedModelId = ""
    @AppStorage("hivelink.reasoningEffort") private var reasoningEffort = "high"

    @State private var text = ""
    @State private var attachmentURLs: [URL] = []
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var showModelPicker = false
    @State private var showExecutionTargetPicker = false
    @State private var showFileImporter = false
    @State private var sendError: String?
    @State private var isSending = false
    @State private var planFirstEnabled = false
    @State private var reasoningCapability = APIReasoningCapability()
    @State private var reasoningEnabled: Bool? = nil
    @State private var editorHeight: CGFloat = 22
    @State private var mentionQuery: HivelinkMentionQuery?
    @StateObject private var mentionProvider = HivelinkMentionSuggestionsProvider()
    @StateObject private var mentionInsertionController = HivelinkMentionInsertionController()

    @State private var fieldFocused = false

    @State private var selectedExecutionTarget: TaskExecutionTarget = .automatic

    private let cornerRadius: CGFloat = 16

    private var rect: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    private var outlineColor: Color {
        fieldFocused ? .accentColor : .primary.opacity(0.3)
    }

    private var effectiveProviderName: String {
        if !storedProviderName.isEmpty { return storedProviderName }
        return firstAvailableChoice()?.providerName ?? ""
    }

    private var effectiveModelId: String {
        if !storedModelId.isEmpty { return storedModelId }
        return firstAvailableChoice()?.modelId ?? ""
    }

    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSubmit: Bool {
        hasText || mentionInsertionController.hasMentions
    }

    private var showsSendButton: Bool {
        canSubmit
    }

    private var finishedTasksForMentions: [TaskRecord] {
        taskService.tasks
            .filter { !$0.status.isActive }
            .sorted { lhs, rhs in
                let lhsDate = lhs.completedAt ?? lhs.createdAt
                let rhsDate = rhs.completedAt ?? rhs.createdAt
                if lhsDate == rhsDate {
                    return lhs.createdAt > rhs.createdAt
                }
                return lhsDate > rhsDate
            }
    }

    private var showMentionSuggestions: Bool {
        mentionQuery != nil && !mentionProvider.suggestions.isEmpty
    }

    /// Re-fires whenever the selected model changes OR peers come online,
    /// so reasoning capability loads correctly at app launch.
    private var reasoningCapabilityTaskID: String {
        let onlineCount = clusterCoordinator.peers.filter { $0.status == .online }.count
        return "\(effectiveProviderName)::\(effectiveModelId)::\(onlineCount)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showMentionSuggestions {
                mentionSuggestionsView
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if !attachmentURLs.isEmpty {
                attachmentChips
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            mainInputContainer
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
        }
        .animation(.easeInOut(duration: 0.2), value: attachmentURLs.count)
        .onAppear {
            restoreVoiceTaskLaunchSnapshotIfAvailable()
            seedDefaultsIfNeeded()
            persistVoiceTaskLaunchSnapshot()
            mentionProvider.updateAttachments(attachmentURLs)
            mentionProvider.updateTasks(finishedTasksForMentions)
        }
        .onReceive(NotificationCenter.default.publisher(for: .loadTaskIntoPromptBar)) { notification in
            guard let taskId = notification.userInfo?["taskId"] as? String,
                  let task = taskService.getTask(byId: taskId) else { return }
            loadTaskIntoPromptBar(task)
        }
        .onReceive(NotificationCenter.default.publisher(for: .continueFromTask)) { notification in
            guard let taskId = notification.userInfo?["taskId"] as? String,
                  let task = taskService.getTask(byId: taskId) else { return }
            loadContinuationSource(task)
        }
        .task(id: reasoningCapabilityTaskID) {
            await loadReasoningCapability()
        }
        .onChange(of: storedProviderName) { _, _ in
            persistVoiceTaskLaunchSnapshot()
        }
        .onChange(of: storedModelId) { _, _ in
            persistVoiceTaskLaunchSnapshot()
        }
        .onChange(of: selectedExecutionTarget) { _, _ in
            persistVoiceTaskLaunchSnapshot()
        }
        .onChange(of: reasoningEnabled) { _, _ in
            persistVoiceTaskLaunchSnapshot()
        }
        .onChange(of: reasoningEffort) { _, _ in
            persistVoiceTaskLaunchSnapshot()
        }
        .onChange(of: photoPickerItems) { _, newValue in
            Task { await ingestPhotoItems(newValue) }
        }
        .onChange(of: attachmentURLs) { _, newValue in
            mentionProvider.updateAttachments(newValue)
        }
        .onChange(of: taskService.tasks) { _, _ in
            mentionProvider.updateTasks(finishedTasksForMentions)
        }
        .sheet(isPresented: $showModelPicker) {
            ModelPickerSheet(
                selectedProviderName: $storedProviderName,
                selectedModelId: $storedModelId,
                isPresented: $showModelPicker,
                peers: clusterCoordinator.peers
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showExecutionTargetPicker) {
            executionTargetSheet
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                for url in urls {
                    if let copied = copyImportToTemporary(url) {
                        attachmentURLs.append(copied)
                    }
                }
            }
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

    // MARK: - Main Container

    private var mainInputContainer: some View {
        HStack(alignment: .center, spacing: 0) {
            attachmentMenuButton
                .frame(width: 28)
                .padding(.leading, 8)

            VStack(alignment: .leading, spacing: 6) {
                HivelinkPromptTextEditor(
                    text: $text,
                    measuredHeight: $editorHeight,
                    placeholder: String(localized: "Describe a task…"),
                    onMentionQuery: { query in
                        mentionQuery = query
                        mentionProvider.updateQuery(query?.query)
                    },
                    mentionInsertionController: mentionInsertionController,
                    onFocusChanged: { isFocused in
                        fieldFocused = isFocused
                    }
                )
                .padding(.leading, 6)
                .frame(minHeight: 22, idealHeight: editorHeight, maxHeight: max(22, editorHeight))

                controlsRow
            }
            .padding(.vertical, 10)

            Spacer(minLength: 8)

            Group {
                if showsSendButton {
                    sendButton
                        .transition(.scale.combined(with: .opacity))
                } else {
                    voiceButton
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.trailing, 8)
            .animation(.easeInOut(duration: 0.25), value: showsSendButton)
        }
        .background(Color(.systemBackground))
        .clipShape(rect)
        .overlay(
            rect
                .stroke(style: StrokeStyle(lineWidth: 1))
                .foregroundStyle(outlineColor)
        )
    }

    // MARK: - Controls Row

    private var controlsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                modelCapsule
                reasoningCapsule
                executionTargetCapsule
                planToggle
            }
            .padding(.horizontal, 6)
        }
        .mask(
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 6)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 8)
            }
        )
    }

    // MARK: - Model Capsule

    private var modelCapsule: some View {
        Button { showModelPicker = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "brain")
                    .font(.caption)
                Text(modelCapsuleLabel)
                    .font(.caption)
                    .lineLimit(1)
            }
            .modifier(PromptCapsuleStyle(
                isActive: !effectiveModelId.isEmpty,
                isFocused: fieldFocused
            ))
        }
        .buttonStyle(.plain)
    }

    private var modelCapsuleLabel: String {
        let m = effectiveModelId
        if m.isEmpty { return String(localized: "Select model") }
        return m
    }

    // MARK: - Reasoning Capsule

    @ViewBuilder
    private var reasoningCapsule: some View {
        switch reasoningCapability.kind {
        case .none:
            EmptyView()
        case .toggle:
            reasoningToggleCapsule
        case .effort:
            reasoningEffortMenu
        }
    }

    private var effectiveReasoningEnabled: Bool {
        reasoningEnabled ?? reasoningCapability.defaultEnabled
    }

    private var reasoningToggleCapsule: some View {
        Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                reasoningEnabled = !effectiveReasoningEnabled
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "brain.head.profile")
                    .font(.caption)
                Text(String(localized: "Reason"))
                    .font(.caption)
                    .lineLimit(1)
            }
            .modifier(PromptCapsuleStyle(
                isActive: effectiveReasoningEnabled,
                isFocused: fieldFocused
            ))
        }
        .buttonStyle(.plain)
    }

    private var effortOptions: [String] {
        let efforts = reasoningCapability.supportedEfforts
        return efforts.isEmpty ? ["low", "medium", "high", "xhigh"] : efforts
    }

    private var reasoningEffortMenu: some View {
        Menu {
            ForEach(effortOptions, id: \.self) { effort in
                Button {
                    reasoningEffort = effort
                } label: {
                    HStack {
                        Text(reasoningEffortDisplayName(effort))
                        if reasoningEffort == effort {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "brain.head.profile")
                    .font(.caption)
                Text(reasoningEffortDisplayName(reasoningEffort))
                    .font(.caption)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .modifier(PromptCapsuleStyle(
                isActive: true,
                isFocused: fieldFocused
            ))
        }
    }

    private func reasoningEffortDisplayName(_ effort: String) -> String {
        let normalized = effort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "xhigh": return String(localized: "Extra High")
        default:
            return normalized
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        }
    }

    // MARK: - Execution Target Capsule

    private var executionTargetCapsule: some View {
        Button { showExecutionTargetPicker = true } label: {
            HStack(spacing: 4) {
                Image(systemName: executionTargetIcon)
                    .font(.caption)
                Text(executionTargetLabel)
                    .font(.caption)
                    .lineLimit(1)
            }
            .modifier(PromptCapsuleStyle(
                isActive: true,
                isFocused: fieldFocused
            ))
        }
        .buttonStyle(.plain)
    }

    private var executionTargetLabel: String {
        switch selectedExecutionTarget.kind {
        case .automatic:
            return String(localized: "Auto")
        case .peer:
            return selectedExecutionTarget.peerName
                ?? selectedExecutionTarget.peerId
                ?? String(localized: "Peer")
        default:
            return selectedExecutionTarget.displayName
        }
    }

    private var executionTargetIcon: String {
        switch selectedExecutionTarget.kind {
        case .automatic: return "arrow.triangle.branch"
        case .peer: return "desktopcomputer"
        default: return "server.rack"
        }
    }

    // MARK: - Plan Toggle

    @State private var directSegmentWidth: CGFloat = 0
    @State private var planSegmentWidth: CGFloat = 0
    @State private var segmentHeight: CGFloat = 0

    private var slidingCapsuleOffset: CGFloat {
        planFirstEnabled ? directSegmentWidth : 0
    }

    private var slidingCapsuleWidth: CGFloat {
        planFirstEnabled ? planSegmentWidth : directSegmentWidth
    }

    private var planToggle: some View {
        HStack(spacing: 0) {
            planSegment(mode: .direct)
                .background(GeometryReader { geo in
                    Color.clear.preference(key: DirectSegmentWidthKey.self, value: geo.size.width)
                })
            planSegment(mode: .plan)
                .background(GeometryReader { geo in
                    Color.clear.preference(key: PlanSegmentWidthKey.self, value: geo.size.width)
                })
        }
        .background(GeometryReader { geo in
            Color.clear.preference(key: SegmentHeightKey.self, value: geo.size.height)
        })
        .background(alignment: .leading) {
            Capsule()
                .fill(fieldFocused ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.08))
                .frame(
                    width: slidingCapsuleWidth > 0 ? slidingCapsuleWidth : nil,
                    height: segmentHeight > 0 ? segmentHeight : nil
                )
                .offset(x: slidingCapsuleOffset)
        }
        .background {
            Capsule()
                .stroke(style: StrokeStyle(lineWidth: 0.5))
                .fill(fieldFocused ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.3))
        }
        .onPreferenceChange(DirectSegmentWidthKey.self) { directSegmentWidth = $0 }
        .onPreferenceChange(PlanSegmentWidthKey.self) { planSegmentWidth = $0 }
        .onPreferenceChange(SegmentHeightKey.self) { segmentHeight = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: planFirstEnabled)
    }

    private func planSegment(mode: PlanMode) -> some View {
        let isSelected = (mode == .plan) == planFirstEnabled
        return Button {
            planFirstEnabled = (mode == .plan)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: mode.iconName)
                    .font(.caption)
                Text(mode.displayName)
                    .font(.caption)
            }
            .foregroundStyle(segmentTextColor(isSelected: isSelected))
            .padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func segmentTextColor(isSelected: Bool) -> Color {
        if isSelected {
            return fieldFocused ? .accentColor.opacity(0.8) : .primary.opacity(0.5)
        }
        return .secondary.opacity(0.5)
    }

    // MARK: - Input Row Components

    private var attachmentMenuButton: some View {
        Menu {
            Button {
                showFileImporter = true
            } label: {
                Label(String(localized: "Import File"), systemImage: "folder")
            }
            PhotosPicker(
                selection: $photoPickerItems,
                maxSelectionCount: 8,
                matching: .any(of: [.images, .videos])
            ) {
                Label(String(localized: "Photo Library"), systemImage: "photo.on.rectangle")
            }
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 16))
                .foregroundStyle(fieldFocused ? Color.accentColor : Color.secondary)
        }
    }

    private var sendButton: some View {
        Button {
            Task { await sendTask() }
        } label: {
            if isSending {
                ProgressView()
                    .frame(width: 24, height: 24)
            } else {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.tint)
            }
        }
        .disabled(isSending || effectiveProviderName.isEmpty || effectiveModelId.isEmpty || !canSubmit)
        .accessibilityLabel(String(localized: "Send task"))
    }

    @EnvironmentObject private var voiceOrchestrator: HivelinkVoiceOrchestrator

    private var voiceButton: some View {
        Button {
            tabSelection = 1
            if voiceOrchestrator.isVoiceConfigured && voiceOrchestrator.callState == .idle {
                voiceOrchestrator.startCall()
            }
        } label: {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 24))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(fieldFocused ? Color.accentColor : Color.secondary)
        }
        .accessibilityLabel(String(localized: "Voice call"))
    }

    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(attachmentURLs.enumerated()), id: \.offset) { index, url in
                    HStack(spacing: 4) {
                        Image(systemName: "doc.fill")
                            .font(.caption2)
                        Text(url.lastPathComponent)
                            .font(.caption2)
                            .lineLimit(1)
                        Button {
                            attachmentURLs.remove(at: index)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.quaternary, in: Capsule())
                }
            }
        }
    }

    private var mentionSuggestionsView: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                if mentionProvider.suggestions.contains(where: { $0.type == .attachment }) {
                    mentionSectionHeader("Attachments")
                    ForEach(mentionProvider.suggestions.filter { $0.type == .attachment }) { suggestion in
                        mentionSuggestionRow(suggestion)
                    }
                }

                if mentionProvider.suggestions.contains(where: { $0.type == .deliverable }) {
                    mentionSectionHeader("Deliverables")
                    ForEach(mentionProvider.suggestions.filter { $0.type == .deliverable }) { suggestion in
                        mentionSuggestionRow(suggestion)
                    }
                }

                if mentionProvider.suggestions.contains(where: { $0.type == .task }) {
                    mentionSectionHeader("Finished Tasks")
                    ForEach(mentionProvider.suggestions.filter { $0.type == .task }) { suggestion in
                        mentionSuggestionRow(suggestion)
                    }
                }
            }
        }
        .frame(maxHeight: 280)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func mentionSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 2)
    }

    private func mentionSuggestionRow(_ suggestion: HivelinkMentionSuggestion) -> some View {
        Button {
            insertMentionSuggestion(suggestion)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: suggestion.iconName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.displayName)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let detail = suggestion.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Execution Target Sheet

    private var executionTargetSheet: some View {
        NavigationStack {
            List {
                Button {
                    selectedExecutionTarget = .automatic
                    showExecutionTargetPicker = false
                } label: {
                    HStack {
                        Label(String(localized: "Automatic"), systemImage: "arrow.triangle.branch")
                        Spacer()
                        if selectedExecutionTarget.kind == .automatic {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                                .fontWeight(.semibold)
                        }
                    }
                }
                Section(String(localized: "Peers")) {
                    let onlinePeers = clusterCoordinator.peers.filter { $0.status == .online }
                    if onlinePeers.isEmpty {
                        Text(String(localized: "No peers online"))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(onlinePeers) { peer in
                            Button {
                                selectedExecutionTarget = .peer(id: peer.id, name: peer.name ?? peer.subdomain)
                                showExecutionTargetPicker = false
                            } label: {
                                HStack {
                                    Label(peer.name ?? peer.subdomain, systemImage: "desktopcomputer")
                                    Spacer()
                                    if selectedExecutionTarget.kind == .peer,
                                       selectedExecutionTarget.peerId == peer.id {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                            .fontWeight(.semibold)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "Run on"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Done")) { showExecutionTargetPicker = false }
                }
            }
        }
    }

    // MARK: - Helpers

    private func firstAvailableChoice() -> (providerName: String, modelId: String)? {
        for peer in clusterCoordinator.peers where peer.status == .online {
            for provider in peer.providers {
                if let first = provider.modelIds.first {
                    return (provider.providerName, first)
                }
            }
        }
        return nil
    }

    private func insertMentionSuggestion(_ suggestion: HivelinkMentionSuggestion) {
        mentionInsertionController.insertSuggestion(suggestion)
        if let url = suggestion.fileURL,
           (suggestion.type == .attachment || suggestion.type == .deliverable),
           !attachmentURLs.contains(where: { $0.path == url.path }) {
            attachmentURLs.append(url)
        }
        mentionQuery = nil
        mentionProvider.updateQuery(nil)
        mentionInsertionController.focusTextView()
        fieldFocused = true
    }

    private func seedDefaultsIfNeeded() {
        guard storedProviderName.isEmpty || storedModelId.isEmpty,
              let first = firstAvailableChoice()
        else { return }
        if storedProviderName.isEmpty { storedProviderName = first.providerName }
        if storedModelId.isEmpty { storedModelId = first.modelId }
    }

    private func restoreVoiceTaskLaunchSnapshotIfAvailable() {
        guard let data = UserDefaults.standard.data(forKey: Self.voiceTaskLaunchSnapshotDefaultsKey),
              let snapshot = try? JSONDecoder().decode(VoiceTaskLaunchSnapshot.self, from: data)
        else { return }

        let providerName = snapshot.providerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelId = snapshot.modelId.trimmingCharacters(in: .whitespacesAndNewlines)

        if !providerName.isEmpty {
            storedProviderName = providerName
        }
        if !modelId.isEmpty {
            storedModelId = modelId
        }

        selectedExecutionTarget = snapshot.executionTarget
        reasoningEnabled = snapshot.reasoningEnabled

        if let effort = snapshot.reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines),
           !effort.isEmpty {
            reasoningEffort = effort
        }
    }

    private func providerId(forProviderName name: String) -> String {
        TaskRecord.remoteOnlyProviderPrefix + name
    }

    private func loadReasoningCapability() async {
        let provider = effectiveProviderName
        let model = effectiveModelId
        guard !provider.isEmpty, !model.isEmpty else { return }

        let capability = await clusterCoordinator.fetchReasoningCapability(
            providerName: provider,
            modelId: model
        )
        reasoningCapability = capability

        switch capability.kind {
        case .toggle:
            reasoningEnabled = capability.defaultEnabled
        case .effort:
            let efforts = capability.supportedEfforts
            if !efforts.isEmpty, !efforts.contains(reasoningEffort) {
                reasoningEffort = efforts.contains("high") ? "high" : efforts[0]
            }
        case .none:
            reasoningEnabled = nil
        }

        persistVoiceTaskLaunchSnapshot()
    }

    private func sendTask() async {
        let resolvedText = mentionInsertionController.getResolvedText(fallbackText: text)
        let trimmed = resolvedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSubmit else { return }
        guard !effectiveProviderName.isEmpty, !effectiveModelId.isEmpty else { return }

        isSending = true
        defer { isSending = false }

        let resolvedReasoningEnabled: Bool?
        let resolvedReasoningEffort: String?
        switch reasoningCapability.kind {
        case .toggle:
            resolvedReasoningEnabled = effectiveReasoningEnabled
            resolvedReasoningEffort = nil
        case .effort:
            resolvedReasoningEnabled = nil
            resolvedReasoningEffort = reasoningEffort
        case .none:
            resolvedReasoningEnabled = nil
            resolvedReasoningEffort = nil
        }

        let paths = attachmentURLs.map(\.path)
        let referencedTaskIds = mentionInsertionController.getReferencedTaskIDs()
        let continuationSourceTaskId = mentionInsertionController.getPrimaryContinuationTaskID()
        let request = TaskCreationRequest(
            description: trimmed,
            providerId: providerId(forProviderName: effectiveProviderName),
            modelId: effectiveModelId,
            executionTarget: selectedExecutionTarget,
            reasoningEnabled: resolvedReasoningEnabled,
            reasoningEffort: resolvedReasoningEffort,
            attachedFilePaths: paths,
            referencedTaskIds: referencedTaskIds,
            continuationSourceTaskId: continuationSourceTaskId,
            planFirstEnabled: planFirstEnabled
        )

        HapticManager.submitPrompt()

        do {
            _ = try await taskService.createTasks([request])
            text = ""
            attachmentURLs = []
            photoPickerItems = []
            mentionQuery = nil
            mentionProvider.updateQuery(nil)
            mentionInsertionController.clearTextView()
            fieldFocused = false
        } catch {
            sendError = error.localizedDescription
        }
    }

    private func loadTaskIntoPromptBar(_ task: TaskRecord) {
        text = task.taskDescription

        let providerName = taskService.getProviderName(for: task.providerId)
        storedProviderName = providerName
        storedModelId = task.modelId

        if let re = task.reasoningEnabled {
            reasoningEnabled = re
        }
        if let effort = task.reasoningEffort, !effort.isEmpty {
            reasoningEffort = effort
        }

        switch task.executionTarget.kind {
        case .peer:
            selectedExecutionTarget = task.executionTarget
        default:
            selectedExecutionTarget = .automatic
        }
        planFirstEnabled = task.planFirstEnabled

        attachmentURLs = task.attachmentInfos.compactMap { info in
            let url = URL(fileURLWithPath: info.effectivePath)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        }

        photoPickerItems = []
        mentionInsertionController.setPlainText(task.taskDescription)
        mentionQuery = nil
        mentionProvider.updateQuery(nil)

        if let continuationTaskId = task.continuationSourceTaskId,
           let continuationTask = taskService.getTask(byId: continuationTaskId) {
            mentionInsertionController.insertTaskSuggestion(
                HivelinkMentionSuggestion(task: continuationTask),
                isPrimaryContinuation: true
            )
        }

        DispatchQueue.main.async {
            mentionInsertionController.focusTextView()
            fieldFocused = true
        }
    }

    private func loadContinuationSource(_ task: TaskRecord) {
        mentionInsertionController.insertTaskSuggestion(
            HivelinkMentionSuggestion(task: task),
            isPrimaryContinuation: true
        )
        mentionQuery = nil
        mentionProvider.updateQuery(nil)
        mentionInsertionController.focusTextView()
        fieldFocused = true
    }

    private func copyImportToTemporary(_ url: URL) -> URL? {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "_" + url.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    private func ingestPhotoItems(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        for item in items {
            do {
                if let data = try await item.loadTransferable(type: Data.self) {
                    let dest = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString + ".jpg")
                    try data.write(to: dest)
                    attachmentURLs.append(dest)
                }
            } catch {
                continue
            }
        }
        photoPickerItems = []
    }

    private func persistVoiceTaskLaunchSnapshot() {
        let providerName = effectiveProviderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelId = effectiveModelId.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !providerName.isEmpty, !modelId.isEmpty else {
            UserDefaults.standard.removeObject(forKey: Self.voiceTaskLaunchSnapshotDefaultsKey)
            return
        }

        let snapshot = VoiceTaskLaunchSnapshot(
            providerName: providerName,
            modelId: modelId,
            executionTarget: selectedExecutionTarget,
            reasoningEnabled: reasoningEnabled,
            reasoningEffort: reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        guard let data = try? JSONEncoder().encode(snapshot) else {
            UserDefaults.standard.removeObject(forKey: Self.voiceTaskLaunchSnapshotDefaultsKey)
            return
        }

        UserDefaults.standard.set(data, forKey: Self.voiceTaskLaunchSnapshotDefaultsKey)
    }
}

// MARK: - Inline Mention Editing

private struct HivelinkMentionQuery {
    let query: String
    let range: NSRange
}

private struct HivelinkMentionSuggestion: Identifiable, Equatable {
    enum SuggestionType {
        case attachment
        case deliverable
        case task
    }

    let id: String
    let displayName: String
    let detail: String?
    let type: SuggestionType
    let fileURL: URL?
    let taskId: String?

    var iconName: String {
        switch type {
        case .attachment: return "paperclip"
        case .deliverable: return "doc.on.doc"
        case .task: return "arrow.turn.down.right"
        }
    }

    init(attachmentURL: URL) {
        id = "attachment:\(attachmentURL.path)"
        displayName = attachmentURL.lastPathComponent
        detail = "Current attachment"
        type = .attachment
        fileURL = attachmentURL
        taskId = nil
    }

    init(deliverableURL: URL, taskTitle: String) {
        id = "deliverable:\(deliverableURL.path)"
        displayName = deliverableURL.lastPathComponent
        detail = taskTitle
        type = .deliverable
        fileURL = deliverableURL
        taskId = nil
    }

    init(task: TaskRecord) {
        id = "task:\(task.id)"
        displayName = task.title
        detail = "\(task.status.displayName) • \((task.completedAt ?? task.createdAt).formatted(date: .abbreviated, time: .omitted))"
        type = .task
        fileURL = nil
        taskId = task.id
    }
}

@MainActor
private final class HivelinkMentionSuggestionsProvider: ObservableObject {
    @Published private(set) var suggestions: [HivelinkMentionSuggestion] = []

    private var attachmentSuggestions: [HivelinkMentionSuggestion] = []
    private var deliverableSuggestions: [HivelinkMentionSuggestion] = []
    private var taskSuggestions: [HivelinkMentionSuggestion] = []
    private var lastQuery: String?

    func updateAttachments(_ urls: [URL]) {
        attachmentSuggestions = urls.map { HivelinkMentionSuggestion(attachmentURL: $0) }
        updateQuery(lastQuery)
    }

    func updateTasks(_ tasks: [TaskRecord]) {
        taskSuggestions = tasks.map { HivelinkMentionSuggestion(task: $0) }
        deliverableSuggestions = tasks
            .flatMap { task in
                (task.outputFilePaths ?? [])
                    .filter { FileManager.default.fileExists(atPath: $0) }
                    .map {
                        HivelinkMentionSuggestion(
                            deliverableURL: URL(fileURLWithPath: $0),
                            taskTitle: task.title
                        )
                    }
            }
        updateQuery(lastQuery)
    }

    func updateQuery(_ query: String?) {
        lastQuery = query
        let trimmed = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else {
            suggestions = []
            return
        }

        let attachments = rankedSuggestions(in: attachmentSuggestions, query: trimmed)
        let filteredDeliverables = deliverableSuggestions.filter { deliverable in
            guard let url = deliverable.fileURL else { return true }
            return !attachmentSuggestions.contains { $0.fileURL?.path == url.path }
        }
        let deliverables = rankedSuggestions(in: filteredDeliverables, query: trimmed)
        let tasks = rankedSuggestions(in: taskSuggestions, query: trimmed)
        suggestions = Array(attachments.prefix(4)) + Array(deliverables.prefix(6)) + Array(tasks.prefix(6))
    }

    private func rankedSuggestions(
        in source: [HivelinkMentionSuggestion],
        query: String
    ) -> [HivelinkMentionSuggestion] {
        source
            .compactMap { suggestion -> (Int, HivelinkMentionSuggestion)? in
                let haystack = "\(suggestion.displayName) \(suggestion.detail ?? "")".lowercased()
                if haystack.hasPrefix(query) { return (0, suggestion) }
                if haystack.contains(query) { return (1, suggestion) }
                return nil
            }
            .sorted { lhs, rhs in
                if lhs.0 == rhs.0 {
                    return lhs.1.displayName.localizedCaseInsensitiveCompare(rhs.1.displayName) == .orderedAscending
                }
                return lhs.0 < rhs.0
            }
            .map(\.1)
    }
}

private enum HivelinkMentionType {
    case attachment
    case deliverable
    case task
}

private struct HivelinkMentionMetadata {
    let displayName: String
    let mentionType: HivelinkMentionType
    let fileURL: URL?
    let taskId: String?
    let isPrimaryContinuation: Bool
}

private extension NSAttributedString.Key {
    static let hivelinkMentionMetadata = NSAttributedString.Key("hivelinkMentionMetadata")
}

private func makeMentionAttachmentString(_ metadata: HivelinkMentionMetadata) -> NSAttributedString {
    let fontSize = UIFont.systemFontSize - 3
    let font = UIFont.systemFont(ofSize: fontSize, weight: .medium)
    let iconFont = UIFont.systemFont(ofSize: fontSize - 2, weight: .medium)
    let horizontalPadding: CGFloat = 4
    let verticalPadding: CGFloat = 2
    let iconSpacing: CGFloat = 4
    let cornerRadius: CGFloat = 5
    let maxTextWidth: CGFloat = 220

    let textColor = UIColor.label
    let backgroundColor: UIColor
    let iconName: String

    switch metadata.mentionType {
    case .attachment:
        backgroundColor = UIColor.systemBlue.withAlphaComponent(0.4)
        iconName = "paperclip"
    case .deliverable:
        backgroundColor = UIColor.systemBlue.withAlphaComponent(0.4)
        iconName = "doc.on.doc"
    case .task:
        backgroundColor = UIColor.systemTeal.withAlphaComponent(0.4)
        iconName = "clock.arrow.trianglehead.counterclockwise.rotate.90"
    }

    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    let textAttributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: textColor,
        .paragraphStyle: paragraph,
    ]
    let constrainedSize = CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude)
    let textRect = (metadata.displayName as NSString).boundingRect(
        with: constrainedSize,
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: textAttributes,
        context: nil
    )

    let iconImage = UIImage(systemName: iconName, withConfiguration: UIImage.SymbolConfiguration(font: iconFont))
    let iconWidth = iconImage?.size.width ?? 0
    let iconHeight = iconImage?.size.height ?? 0
    let totalWidth = horizontalPadding + iconWidth + iconSpacing + ceil(textRect.width) + horizontalPadding
    let totalHeight = max(ceil(textRect.height), iconHeight) + verticalPadding * 2
    let size = CGSize(width: totalWidth, height: totalHeight)

    let image = UIGraphicsImageRenderer(size: size).image { context in
        let rect = CGRect(origin: .zero, size: size)
        let path = UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius)
        backgroundColor.setFill()
        path.fill()

        if let iconImage {
            let iconY = (size.height - iconHeight) / 2
            iconImage.withTintColor(textColor, renderingMode: .alwaysOriginal)
                .draw(at: CGPoint(x: horizontalPadding, y: iconY))
        }

        let drawRect = CGRect(
            x: horizontalPadding + iconWidth + iconSpacing,
            y: (size.height - ceil(textRect.height)) / 2,
            width: ceil(textRect.width),
            height: ceil(textRect.height)
        )
        (metadata.displayName as NSString).draw(in: drawRect, withAttributes: textAttributes)
    }

    let attachment = NSTextAttachment()
    attachment.image = image
    attachment.bounds = CGRect(x: 0, y: -4, width: image.size.width, height: image.size.height)
    let attributed = NSMutableAttributedString(attachment: attachment)
    attributed.addAttribute(.hivelinkMentionMetadata, value: metadata, range: NSRange(location: 0, length: attributed.length))
    return attributed
}

@MainActor
private final class HivelinkMentionInsertionController: ObservableObject {
    private enum PendingInsertion {
        case suggestion(HivelinkMentionSuggestion, Bool)
    }

    weak var textView: UITextView?
    weak var coordinator: HivelinkPromptTextEditor.Coordinator?

    private var pendingPlainText: String?
    private var pendingInsertions: [PendingInsertion] = []

    var hasMentions: Bool {
        guard let textStorage = textView?.textStorage else { return false }
        var found = false
        textStorage.enumerateAttribute(.hivelinkMentionMetadata, in: NSRange(location: 0, length: textStorage.length)) { value, _, stop in
            if value is HivelinkMentionMetadata {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    func attach(textView: UITextView, coordinator: HivelinkPromptTextEditor.Coordinator) {
        self.textView = textView
        self.coordinator = coordinator

        if let pendingPlainText {
            self.pendingPlainText = nil
            setPlainText(pendingPlainText)
        }

        if !pendingInsertions.isEmpty {
            let insertions = pendingInsertions
            pendingInsertions.removeAll()
            for insertion in insertions {
                switch insertion {
                case .suggestion(let suggestion, let isPrimaryContinuation):
                    insertSuggestion(suggestion, isPrimaryContinuation: isPrimaryContinuation)
                }
            }
        }
    }

    func insertSuggestion(_ suggestion: HivelinkMentionSuggestion, isPrimaryContinuation: Bool = false) {
        guard let textView, let coordinator else {
            pendingInsertions.append(.suggestion(suggestion, isPrimaryContinuation))
            return
        }
        coordinator.insertSuggestion(suggestion, isPrimaryContinuation: isPrimaryContinuation, in: textView)
    }

    func insertTaskSuggestion(_ suggestion: HivelinkMentionSuggestion, isPrimaryContinuation: Bool) {
        insertSuggestion(suggestion, isPrimaryContinuation: isPrimaryContinuation)
    }

    func focusTextView() {
        textView?.becomeFirstResponder()
    }

    func clearTextView() {
        guard let textView else {
            pendingPlainText = ""
            pendingInsertions.removeAll()
            return
        }
        textView.attributedText = NSAttributedString(string: "")
        textView.selectedRange = NSRange(location: 0, length: 0)
        textView.setNeedsLayout()
    }

    func setPlainText(_ text: String) {
        guard let textView else {
            pendingPlainText = text
            return
        }
        let attributed = NSAttributedString(
            string: text,
            attributes: HivelinkPromptTextEditor.defaultTypingAttributes
        )
        textView.attributedText = attributed
        textView.selectedRange = NSRange(location: attributed.length, length: 0)
        textView.typingAttributes = HivelinkPromptTextEditor.defaultTypingAttributes
        textView.textColor = .label
        textView.setNeedsLayout()
    }

    func getResolvedText(fallbackText: String) -> String {
        guard let textStorage = textView?.textStorage else { return fallbackText }

        var resolvedText = ""
        let fullRange = NSRange(location: 0, length: textStorage.length)
        textStorage.enumerateAttributes(in: fullRange, options: []) { attributes, range, _ in
            if let metadata = attributes[.hivelinkMentionMetadata] as? HivelinkMentionMetadata {
                switch metadata.mentionType {
                case .attachment:
                    if let fileURL = metadata.fileURL {
                        resolvedText += "\"/Users/hivecrew/Desktop/inbox/\(fileURL.lastPathComponent)\""
                    }
                case .deliverable:
                    if let fileURL = metadata.fileURL {
                        resolvedText += "\"/Users/hivecrew/Desktop/inbox/\(fileURL.lastPathComponent)\""
                    }
                case .task:
                    resolvedText += "Continue from previous task \"\(metadata.displayName)\""
                }
            } else {
                resolvedText += textStorage.attributedSubstring(from: range).string
            }
        }

        return resolvedText
    }

    func getReferencedTaskIDs() -> [String] {
        guard let textStorage = textView?.textStorage else { return [] }

        var taskIDs: [String] = []
        let fullRange = NSRange(location: 0, length: textStorage.length)
        textStorage.enumerateAttributes(in: fullRange, options: []) { attributes, _, _ in
            guard let metadata = attributes[.hivelinkMentionMetadata] as? HivelinkMentionMetadata,
                  metadata.mentionType == .task,
                  let taskId = metadata.taskId,
                  !taskIDs.contains(taskId) else {
                return
            }
            taskIDs.append(taskId)
        }
        return taskIDs
    }

    func getPrimaryContinuationTaskID() -> String? {
        guard let textStorage = textView?.textStorage else { return nil }

        var continuationTaskID: String?
        let fullRange = NSRange(location: 0, length: textStorage.length)
        textStorage.enumerateAttributes(in: fullRange, options: []) { attributes, _, stop in
            guard let metadata = attributes[.hivelinkMentionMetadata] as? HivelinkMentionMetadata,
                  metadata.mentionType == .task,
                  metadata.isPrimaryContinuation,
                  let taskId = metadata.taskId else {
                return
            }
            continuationTaskID = taskId
            stop.pointee = true
        }
        return continuationTaskID
    }
}

private final class HivelinkPromptTextView: UITextView {
    var placeholder: String = ""
    var onFocusChanged: ((Bool) -> Void)?
    private let placeholderLabel = UILabel()
    private let minimumEditorHeight: CGFloat = 22
    private let maximumEditorHeight: CGFloat = 120

    private var placeholderFont: UIFont {
        font ?? UIFont.preferredFont(forTextStyle: .body)
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        configurePlaceholderLabel()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configurePlaceholderLabel()
    }

    override var intrinsicContentSize: CGSize {
        let fittingWidth = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width
        let fittedSize = sizeThatFits(CGSize(width: fittingWidth, height: .greatestFiniteMagnitude))
        let clampedHeight = min(max(fittedSize.height, minimumEditorHeight), maximumEditorHeight)
        return CGSize(width: UIView.noIntrinsicMetric, height: clampedHeight)
    }

    override var contentSize: CGSize {
        didSet {
            if oldValue != contentSize {
                invalidateIntrinsicContentSize()
                setNeedsLayout()
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updatePlaceholderAppearance()
        invalidateIntrinsicContentSize()
    }

    private func configurePlaceholderLabel() {
        placeholderLabel.isUserInteractionEnabled = false
        placeholderLabel.numberOfLines = 1
        placeholderLabel.lineBreakMode = .byTruncatingTail
        placeholderLabel.adjustsFontForContentSizeCategory = true
        addSubview(placeholderLabel)
        updatePlaceholderAppearance()
    }

    func updatePlaceholderAppearance() {
        let font = placeholderFont
        placeholderLabel.text = placeholder
        placeholderLabel.font = font
        placeholderLabel.textColor = UIColor.secondaryLabel
        placeholderLabel.isHidden = attributedText.length > 0

        let lineHeight = ceil(font.lineHeight)
        let horizontalInset = textContainerInset.left + textContainer.lineFragmentPadding
        let availableWidth = bounds.width - horizontalInset - textContainerInset.right - textContainer.lineFragmentPadding
        let originY = max(0, (bounds.height - lineHeight) / 2)
        placeholderLabel.frame = CGRect(
            x: horizontalInset,
            y: originY,
            width: max(0, availableWidth),
            height: lineHeight
        )
    }

    override func becomeFirstResponder() -> Bool {
        let becameFirstResponder = super.becomeFirstResponder()
        onFocusChanged?(becameFirstResponder)
        return becameFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            onFocusChanged?(false)
        }
        return resigned
    }
}

private struct HivelinkPromptTextEditor: UIViewRepresentable {
    static let defaultTypingAttributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.preferredFont(forTextStyle: .body),
        .foregroundColor: UIColor.label,
    ]

    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    let placeholder: String
    let onMentionQuery: (HivelinkMentionQuery?) -> Void
    let mentionInsertionController: HivelinkMentionInsertionController
    let onFocusChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> HivelinkPromptTextView {
        let textView = HivelinkPromptTextView()
        textView.delegate = context.coordinator
        textView.placeholder = placeholder
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.textColor = .label
        textView.tintColor = .systemBlue
        textView.isScrollEnabled = false
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainerInset = UIEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
        textView.typingAttributes = Self.defaultTypingAttributes
        textView.onFocusChanged = onFocusChanged
        mentionInsertionController.attach(textView: textView, coordinator: context.coordinator)
        return textView
    }

    func updateUIView(_ uiView: HivelinkPromptTextView, context: Context) {
        uiView.placeholder = placeholder
        uiView.onFocusChanged = onFocusChanged
        mentionInsertionController.attach(textView: uiView, coordinator: context.coordinator)
        context.coordinator.parent = self

        if !context.coordinator.isProgrammaticUpdate,
           uiView.attributedText.length == 0,
           !text.isEmpty {
            uiView.attributedText = NSAttributedString(string: text, attributes: Self.defaultTypingAttributes)
        }

        DispatchQueue.main.async {
            measuredHeight = context.coordinator.measuredHeight(for: uiView)
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: HivelinkPromptTextEditor
        var isProgrammaticUpdate = false
        private var currentMentionRange: NSRange?

        init(_ parent: HivelinkPromptTextEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            if isProgrammaticUpdate {
                isProgrammaticUpdate = false
                return
            }

            applyDefaultTypingAttributes(to: textView)
            parent.text = plainText(from: textView)
            textView.invalidateIntrinsicContentSize()
            parent.measuredHeight = measuredHeight(for: textView)
            checkForMentionQuery(in: textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            if isProgrammaticUpdate {
                isProgrammaticUpdate = false
                return
            }
            applyDefaultTypingAttributes(to: textView)
            checkForMentionQuery(in: textView)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            applyDefaultTypingAttributes(to: textView)
        }

        func insertSuggestion(
            _ suggestion: HivelinkMentionSuggestion,
            isPrimaryContinuation: Bool,
            in textView: UITextView
        ) {
            let textStorage = textView.textStorage

            if isPrimaryContinuation {
                removePrimaryContinuationMention(in: textView)
            }

            let replacementRange = currentMentionRange ?? textView.selectedRange
            let metadata: HivelinkMentionMetadata

            switch suggestion.type {
            case .attachment:
                guard let fileURL = suggestion.fileURL else { return }
                metadata = HivelinkMentionMetadata(
                    displayName: fileURL.lastPathComponent,
                    mentionType: .attachment,
                    fileURL: fileURL,
                    taskId: nil,
                    isPrimaryContinuation: false
                )
            case .deliverable:
                guard let fileURL = suggestion.fileURL else { return }
                metadata = HivelinkMentionMetadata(
                    displayName: fileURL.lastPathComponent,
                    mentionType: .deliverable,
                    fileURL: fileURL,
                    taskId: nil,
                    isPrimaryContinuation: false
                )
            case .task:
                guard let taskId = suggestion.taskId else { return }
                metadata = HivelinkMentionMetadata(
                    displayName: suggestion.displayName,
                    mentionType: .task,
                    fileURL: nil,
                    taskId: taskId,
                    isPrimaryContinuation: isPrimaryContinuation
                )
            }

            isProgrammaticUpdate = true

            let combined = NSMutableAttributedString()
            combined.append(makeMentionAttachmentString(metadata))
            combined.append(NSAttributedString(string: " ", attributes: HivelinkPromptTextEditor.defaultTypingAttributes))
            textStorage.replaceCharacters(in: replacementRange, with: combined)

            let newCursor = replacementRange.location + combined.length
            textView.selectedRange = NSRange(location: newCursor, length: 0)
            applyDefaultTypingAttributes(to: textView)

            parent.text = plainText(from: textView)
            textView.invalidateIntrinsicContentSize()
            parent.measuredHeight = measuredHeight(for: textView)
            currentMentionRange = nil
            parent.onMentionQuery(nil)
            textView.setNeedsLayout()
        }

        private func removePrimaryContinuationMention(in textView: UITextView) {
            let textStorage = textView.textStorage

            let fullRange = NSRange(location: 0, length: textStorage.length)
            var rangesToDelete: [NSRange] = []

            textStorage.enumerateAttribute(.hivelinkMentionMetadata, in: fullRange, options: []) { value, range, _ in
                guard let metadata = value as? HivelinkMentionMetadata,
                      metadata.mentionType == .task,
                      metadata.isPrimaryContinuation else {
                    return
                }

                var deletionRange = range
                if NSMaxRange(range) < textStorage.length {
                    let trailingChar = textStorage.attributedSubstring(from: NSRange(location: NSMaxRange(range), length: 1)).string
                    if trailingChar == " " {
                        deletionRange.length += 1
                    }
                }
                rangesToDelete.append(deletionRange)
            }

            for range in rangesToDelete.reversed() {
                textStorage.deleteCharacters(in: range)
            }
        }

        private func plainText(from textView: UITextView) -> String {
            let textStorage = textView.textStorage

            var result = ""
            let fullRange = NSRange(location: 0, length: textStorage.length)
            textStorage.enumerateAttributes(in: fullRange, options: []) { attributes, range, _ in
                if attributes[.hivelinkMentionMetadata] is HivelinkMentionMetadata {
                    return
                }
                result += textStorage.attributedSubstring(from: range).string
            }
            return result
        }

        private func applyDefaultTypingAttributes(to textView: UITextView) {
            textView.typingAttributes = HivelinkPromptTextEditor.defaultTypingAttributes
            textView.textColor = .label
        }

        func measuredHeight(for textView: UITextView) -> CGFloat {
            let fittingWidth = textView.bounds.width > 0 ? textView.bounds.width : UIScreen.main.bounds.width
            let fittedSize = textView.sizeThatFits(CGSize(width: fittingWidth, height: .greatestFiniteMagnitude))
            return min(max(fittedSize.height, 22), 120)
        }

        private func checkForMentionQuery(in textView: UITextView) {
            let text = textView.attributedText.string
            let cursorLocation = textView.selectedRange.location

            guard cursorLocation > 0, cursorLocation <= text.count else {
                currentMentionRange = nil
                parent.onMentionQuery(nil)
                return
            }

            let textBeforeCursor = String(text.prefix(cursorLocation))
            guard let atIndex = textBeforeCursor.lastIndex(of: "@") else {
                currentMentionRange = nil
                parent.onMentionQuery(nil)
                return
            }

            if atIndex > textBeforeCursor.startIndex {
                let characterBeforeAt = textBeforeCursor[textBeforeCursor.index(before: atIndex)]
                if !characterBeforeAt.isWhitespace && !characterBeforeAt.isNewline {
                    currentMentionRange = nil
                    parent.onMentionQuery(nil)
                    return
                }
            }

            let queryStartIndex = textBeforeCursor.index(after: atIndex)
            let queryText = String(textBeforeCursor[queryStartIndex...])
            if queryText.isEmpty || queryText.contains(where: { $0.isWhitespace || $0.isNewline || $0 == "\u{FFFC}" }) {
                currentMentionRange = nil
                parent.onMentionQuery(nil)
                return
            }

            let atPosition = textBeforeCursor.distance(from: textBeforeCursor.startIndex, to: atIndex)
            let mentionRange = NSRange(location: atPosition, length: queryText.count + 1)
            currentMentionRange = mentionRange
            parent.onMentionQuery(HivelinkMentionQuery(query: queryText, range: mentionRange))
        }
    }
}

// MARK: - Capsule Style Modifier

private struct PromptCapsuleStyle: ViewModifier {
    var isActive: Bool
    var isFocused: Bool

    private var textColor: Color {
        if isFocused && isActive {
            return .accentColor
        }
        return (isActive ? Color.primary : Color.secondary).opacity(0.5)
    }

    private var fillColor: Color {
        if isFocused && isActive {
            return Color.accentColor.opacity(0.25)
        }
        return Color.primary.opacity(0.05)
    }

    private var borderColor: Color {
        if isFocused && isActive {
            return Color.accentColor.opacity(0.35)
        }
        return Color.primary.opacity(0.2)
    }

    private static let capsuleHeight: CGFloat = 28

    func body(content: Content) -> some View {
        content
            .foregroundStyle(textColor)
            .padding(.horizontal, 8)
            .frame(height: Self.capsuleHeight)
            .background {
                ZStack {
                    Capsule()
                        .fill(fillColor)
                    Capsule()
                        .stroke(style: StrokeStyle(lineWidth: 0.5))
                        .fill(borderColor)
                }
            }
    }
}

// MARK: - Plan Mode

private enum PlanMode {
    case direct, plan

    var iconName: String {
        switch self {
        case .direct: return "bolt.fill"
        case .plan: return "list.bullet.clipboard"
        }
    }

    var displayName: String {
        switch self {
        case .direct: return String(localized: "Direct")
        case .plan: return String(localized: "Plan")
        }
    }
}

// MARK: - Model Picker Sheet

private struct ModelPickerSheet: View {
    @Binding var selectedProviderName: String
    @Binding var selectedModelId: String
    @Binding var isPresented: Bool
    let peers: [DiscoveredClusterPeer]

    @State private var searchText = ""
    @State private var pickerProviderName = ""

    private var onlinePeers: [DiscoveredClusterPeer] {
        peers.filter { $0.status == .online }
    }

    private var allProviderNames: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for peer in onlinePeers {
            for provider in peer.providers where !seen.contains(provider.providerName) {
                seen.insert(provider.providerName)
                result.append(provider.providerName)
            }
        }
        return result
    }

    private var activeProviderName: String {
        if !pickerProviderName.isEmpty, allProviderNames.contains(pickerProviderName) {
            return pickerProviderName
        }
        if allProviderNames.contains(selectedProviderName) {
            return selectedProviderName
        }
        return allProviderNames.first ?? ""
    }

    private var modelsForActiveProvider: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for peer in onlinePeers {
            for provider in peer.providers where provider.providerName == activeProviderName {
                for modelId in provider.modelIds where !seen.contains(modelId) {
                    seen.insert(modelId)
                    result.append(modelId)
                }
            }
        }
        return result
    }

    private var filteredModels: [String] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return modelsForActiveProvider }
        return modelsForActiveProvider.filter {
            $0.localizedCaseInsensitiveContains(query)
        }
    }

    private func peerNames(for modelId: String) -> [String] {
        onlinePeers.compactMap { peer in
            let supports = peer.providers.contains { provider in
                provider.providerName == activeProviderName && provider.modelIds.contains(modelId)
            }
            return supports ? (peer.name ?? peer.subdomain) : nil
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if allProviderNames.count > 1 {
                    providerChips
                    Divider()
                }

                searchField

                Divider()

                if onlinePeers.isEmpty {
                    ContentUnavailableView(
                        "No online peers",
                        systemImage: "wifi.slash",
                        description: Text("Open the Cluster tab and wait for workers to come online.")
                    )
                } else if filteredModels.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty ? "No models available" : "No matching models",
                        systemImage: searchText.isEmpty ? "brain" : "magnifyingglass",
                        description: searchText.isEmpty
                            ? Text("No models found for this provider.")
                            : Text("Try a different search term.")
                    )
                } else {
                    modelList
                }
            }
            .navigationTitle(String(localized: "Model"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { isPresented = false }
                }
            }
        }
        .onAppear {
            if pickerProviderName.isEmpty {
                pickerProviderName = selectedProviderName
            }
        }
    }

    // MARK: - Provider Chips

    private var providerChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(allProviderNames, id: \.self) { name in
                    providerChip(name)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func providerChip(_ name: String) -> some View {
        let isSelected = name == activeProviderName
        return Button {
            pickerProviderName = name
            searchText = ""
        } label: {
            Text(name)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    isSelected
                        ? AnyShapeStyle(.tint.opacity(0.22))
                        : AnyShapeStyle(.quaternary),
                    in: Capsule()
                )
                .overlay(
                    Capsule()
                        .strokeBorder(isSelected ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.body)
                .foregroundStyle(.secondary)
            TextField(String(localized: "Search models"), text: $searchText)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: - Model List

    private var modelList: some View {
        List {
            ForEach(filteredModels, id: \.self) { modelId in
                modelRow(modelId)
            }
        }
        .listStyle(.plain)
    }

    private func modelRow(_ modelId: String) -> some View {
        let isSelected = modelId == selectedModelId && activeProviderName == selectedProviderName
        let names = peerNames(for: modelId)

        return Button {
            selectedProviderName = activeProviderName
            selectedModelId = modelId
            isPresented = false
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(modelId)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if names.count > 1 {
                        Text(names.joined(separator: ", "))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Plan Toggle Preference Keys

private struct DirectSegmentWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct PlanSegmentWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct SegmentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

#Preview {
    PromptBar(tabSelection: .constant(0))
        .environmentObject(HivelinkTaskService(modelContext: ModelContext(try! ModelContainer(for: TaskRecord.self)), clusterCoordinator: HivelinkClusterCoordinator(), remoteTaskIndex: RemoteTaskIndex()))
        .environmentObject(HivelinkClusterCoordinator())
        .environmentObject(HivelinkVoiceOrchestrator())
}
