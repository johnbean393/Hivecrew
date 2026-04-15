//
//  PromptBar.swift
//  Hivelink
//

import HivecrewAPIModels
import HivecrewCore
import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct PromptBar: View {
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

    @FocusState private var fieldFocused: Bool

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

    /// Re-fires whenever the selected model changes OR peers come online,
    /// so reasoning capability loads correctly at app launch.
    private var reasoningCapabilityTaskID: String {
        let onlineCount = clusterCoordinator.peers.filter { $0.status == .online }.count
        return "\(effectiveProviderName)::\(effectiveModelId)::\(onlineCount)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
            seedDefaultsIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .loadTaskIntoPromptBar)) { notification in
            guard let taskId = notification.userInfo?["taskId"] as? String,
                  let task = taskService.getTask(byId: taskId) else { return }
            loadTaskIntoPromptBar(task)
        }
        .task(id: reasoningCapabilityTaskID) {
            await loadReasoningCapability()
        }
        .onChange(of: photoPickerItems) { _, newValue in
            Task { await ingestPhotoItems(newValue) }
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
                TextField(
                    String(localized: "Describe a task…"),
                    text: $text,
                    axis: .vertical
                )
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .padding(.leading, 6)

                controlsRow
            }
            .padding(.vertical, 10)

            Spacer(minLength: 8)

            Group {
                if hasText {
                    sendButton
                        .transition(.scale.combined(with: .opacity))
                } else {
                    voiceButton
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.trailing, 8)
            .animation(.easeInOut(duration: 0.25), value: hasText)
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
        .disabled(isSending || effectiveProviderName.isEmpty || effectiveModelId.isEmpty)
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

    private func seedDefaultsIfNeeded() {
        guard storedProviderName.isEmpty || storedModelId.isEmpty,
              let first = firstAvailableChoice()
        else { return }
        if storedProviderName.isEmpty { storedProviderName = first.providerName }
        if storedModelId.isEmpty { storedModelId = first.modelId }
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
    }

    private func sendTask() async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
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
        let request = TaskCreationRequest(
            description: trimmed,
            providerId: providerId(forProviderName: effectiveProviderName),
            modelId: effectiveModelId,
            executionTarget: selectedExecutionTarget,
            reasoningEnabled: resolvedReasoningEnabled,
            reasoningEffort: resolvedReasoningEffort,
            attachedFilePaths: paths,
            planFirstEnabled: planFirstEnabled
        )

        HapticManager.submitPrompt()

        do {
            _ = try await taskService.createTasks([request])
            text = ""
            attachmentURLs = []
            photoPickerItems = []
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

        DispatchQueue.main.async {
            fieldFocused = true
        }
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
