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

    @State private var text = ""
    @State private var attachmentURLs: [URL] = []
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var showModelPicker = false
    @State private var showExecutionTargetPicker = false
    @State private var showAttachmentMenu = false
    @State private var showFileImporter = false
    @State private var sendError: String?
    @State private var isSending = false

    @FocusState private var fieldFocused: Bool

    /// Resolved from stored names + cluster; falls back to first online capability.
    private var effectiveProviderName: String {
        if !storedProviderName.isEmpty { return storedProviderName }
        return firstAvailableChoice()?.providerName ?? ""
    }

    private var effectiveModelId: String {
        if !storedModelId.isEmpty { return storedModelId }
        return firstAvailableChoice()?.modelId ?? ""
    }

    private var executionTargetLabel: String {
        switch selectedExecutionTarget.kind {
        case .automatic:
            return String(localized: "Automatic")
        case .peer:
            return selectedExecutionTarget.peerName
                ?? selectedExecutionTarget.peerId
                ?? String(localized: "Peer")
        default:
            return selectedExecutionTarget.displayName
        }
    }

    @State private var selectedExecutionTarget: TaskExecutionTarget = .automatic

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Button {
                        showModelPicker = true
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(modelSummaryLine)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(String(localized: "Model & provider"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)

                    Button {
                        showExecutionTargetPicker = true
                    } label: {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(executionTargetLabel)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(String(localized: "Run on"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 4)

                if !attachmentURLs.isEmpty {
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

                HStack(alignment: .bottom, spacing: 10) {
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
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.tint)
                    }

                    TextField(
                        String(localized: "Describe a task…"),
                        text: $text,
                        axis: .vertical
                    )
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(.quaternary.opacity(0.85), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .focused($fieldFocused)

                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button {
                            tabSelection = 1
                        } label: {
                            Image(systemName: "mic.circle.fill")
                                .font(.title)
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel(String(localized: "Voice call"))
                    } else {
                        Button {
                            Task { await sendTask() }
                        } label: {
                            if isSending {
                                ProgressView()
                                    .frame(width: 28, height: 28)
                            } else {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.title)
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundStyle(.tint)
                            }
                        }
                        .disabled(isSending || effectiveProviderName.isEmpty || effectiveModelId.isEmpty)
                        .accessibilityLabel(String(localized: "Send task"))
                    }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
        .onAppear {
            seedDefaultsIfNeeded()
        }
        .onChange(of: photoPickerItems) { _, newValue in
            Task { await ingestPhotoItems(newValue) }
        }
        .sheet(isPresented: $showModelPicker) {
            modelPickerSheet
        }
        .sheet(isPresented: $showExecutionTargetPicker) {
            executionTargetSheet
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                for url in urls {
                    if let copied = copyImportToTemporary(url) {
                        attachmentURLs.append(copied)
                    }
                }
            case .failure:
                break
            }
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

    private var modelSummaryLine: String {
        let p = effectiveProviderName
        let m = effectiveModelId
        if p.isEmpty, m.isEmpty { return String(localized: "Select model") }
        if m.isEmpty { return p }
        if p.isEmpty { return m }
        return "\(p) · \(m)"
    }

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

    private func sendTask() async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !effectiveProviderName.isEmpty, !effectiveModelId.isEmpty else { return }

        isSending = true
        defer { isSending = false }

        let paths = attachmentURLs.map(\.path)
        let request = TaskCreationRequest(
            description: trimmed,
            providerId: providerId(forProviderName: effectiveProviderName),
            modelId: effectiveModelId,
            executionTarget: selectedExecutionTarget,
            attachedFilePaths: paths
        )

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
                    let ext = "jpg"
                    let dest = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString + "." + ext)
                    try data.write(to: dest)
                    attachmentURLs.append(dest)
                }
            } catch {
                continue
            }
        }
        photoPickerItems = []
    }

    private var modelPickerSheet: some View {
        NavigationStack {
            List {
                let onlinePeers = clusterCoordinator.peers.filter { $0.status == .online }
                if onlinePeers.isEmpty {
                    ContentUnavailableView(
                        "No online peers",
                        systemImage: "wifi.slash",
                        description: Text("Open the Cluster tab and wait for Mac workers to come online.")
                    )
                } else {
                    ForEach(onlinePeers) { peer in
                        Section(peer.name ?? peer.subdomain) {
                            ForEach(peer.providers, id: \.providerName) { provider in
                                ForEach(provider.modelIds, id: \.self) { modelId in
                                    Button {
                                        storedProviderName = provider.providerName
                                        storedModelId = modelId
                                        showModelPicker = false
                                    } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(provider.providerName)
                                                .font(.headline)
                                            Text(modelId)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "Model & provider"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Done")) { showModelPicker = false }
                }
            }
        }
    }

    private var executionTargetSheet: some View {
        NavigationStack {
            List {
                Button {
                    selectedExecutionTarget = .automatic
                    showExecutionTargetPicker = false
                } label: {
                    HStack {
                        Text(String(localized: "Automatic"))
                        Spacer()
                        if selectedExecutionTarget.kind == .automatic {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.tint)
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
                                    Text(peer.name ?? peer.subdomain)
                                    Spacer()
                                    if selectedExecutionTarget.kind == .peer,
                                       selectedExecutionTarget.peerId == peer.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.tint)
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
}

#Preview {
    PromptBar(tabSelection: .constant(0))
        .environmentObject(HivelinkTaskService(modelContext: ModelContext(try! ModelContainer(for: TaskRecord.self)), clusterCoordinator: HivelinkClusterCoordinator()))
        .environmentObject(HivelinkClusterCoordinator())
}
