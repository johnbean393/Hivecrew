//
//  SettingsView.swift
//  Hivelink
//

import HivecrewAPIModels
import HivecrewCore
import HivecrewShared
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var authManager: RemoteAccessAuthManager
    @EnvironmentObject private var coordinator: HivelinkClusterCoordinator
    @EnvironmentObject private var artifactCoordinator: ArtifactImportCoordinator

    // MARK: - Voice

    @AppStorage("hivelink.voiceProvider") private var voiceProvider = "gemini"
    @AppStorage("hivelink.voiceApiKey") private var voiceApiKey = ""
    @AppStorage("hivelink.voiceName") private var voiceName = "Leda"
    @AppStorage("hivelink.mediaResolution") private var mediaResolution = "medium"
    @AppStorage("hivelink.reasoningEffort") private var reasoningEffort = "low"

    // MARK: - Defaults

    @AppStorage("hivelink.lastProviderName") private var defaultProviderName = ""
    @AppStorage("hivelink.lastModelId") private var defaultModelId = ""
    @AppStorage("hivelink.defaultExecutionTarget") private var defaultExecutionTarget = "automatic"

    // MARK: - Notifications

    @AppStorage("hivelink.notify_completions") private var notifyCompletions = true
    @AppStorage("hivelink.notify_failures") private var notifyFailures = true
    @AppStorage("hivelink.notify_questions") private var notifyQuestions = true
    @AppStorage("hivelink.notify_permissions") private var notifyPermissions = true

    // MARK: - Incoming Calls

    @AppStorage("hivelink.incomingCallsEnabled") private var incomingCallsEnabled = true
    @AppStorage("incomingCall_question") private var callQuestion = true
    @AppStorage("incomingCall_permission") private var callPermission = true
    @AppStorage("incomingCall_completed") private var callCompleted = false
    @AppStorage("incomingCall_failed") private var callFailed = true
    @AppStorage("incomingCall_planReview") private var callPlanReview = false
    @AppStorage("incomingCall_writebackReview") private var callWritebackReview = false

    // MARK: - Storage

    @AppStorage("hivelink.traceRetentionDays") private var traceRetentionDays = 0

    @State private var cacheSize: Int64 = 0
    @State private var showClearCacheConfirmation = false
    @State private var showModelPicker = false
    @State private var showDeleteAccountConfirmation = false
    @State private var showDeleteAccountError = false

    private var onlinePeerCount: Int {
        coordinator.peers.filter { $0.status == .online }.count
    }

    private var peerCount: Int {
        coordinator.peers.count
    }

    var body: some View {
        Form {
            accountSection
            voiceSection
            defaultsSection
            notificationsSection
            incomingCallsSection
            storageSection
            aboutSection
        }
        .task {
            cacheSize = Self.computeCacheSize()
        }
    }

    // MARK: - Account

    private var accountSection: some View {
        Section {
            LabeledContent(String(localized: "Email")) {
                Text(authManager.email ?? String(localized: "Not signed in"))
                    .foregroundStyle(.secondary)
            }

            LabeledContent(String(localized: "Cluster")) {
                Text("\(onlinePeerCount) of \(peerCount) peers online")
                    .foregroundStyle(.secondary)
            }

            Button(role: .destructive) {
                authManager.logout()
            } label: {
                Text(String(localized: "Sign Out"))
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            Button(role: .destructive) {
                showDeleteAccountConfirmation = true
            } label: {
                if authManager.isDeletingAccount {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    Text(String(localized: "Delete Account"))
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .disabled(authManager.isDeletingAccount)
        } header: {
            Text(String(localized: "Account"))
        }
        .alert(
            String(localized: "Delete Account"),
            isPresented: $showDeleteAccountConfirmation
        ) {
            Button(String(localized: "Cancel"), role: .cancel) {}
            Button(String(localized: "Delete"), role: .destructive) {
                Task {
                    await authManager.deleteAccount()
                    if authManager.errorMessage != nil {
                        showDeleteAccountError = true
                    }
                }
            }
        } message: {
            Text(String(localized: "This permanently deletes your account, signed-in devices, and remote access configuration. This action cannot be undone."))
        }
        .alert(
            String(localized: "Delete Account Failed"),
            isPresented: $showDeleteAccountError
        ) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(authManager.errorMessage ?? String(localized: "Something went wrong while deleting your account."))
        }
    }

    // MARK: - Voice

    private var voiceSection: some View {
        Section {
            Picker(String(localized: "Provider"), selection: $voiceProvider) {
                Text("Gemini").tag("gemini")
                Text("OpenAI").tag("openai")
            }

            LabeledContent(String(localized: "API Key")) {
                SecureField(String(localized: "Enter API key"), text: $voiceApiKey)
                    .multilineTextAlignment(.trailing)
            }

            LabeledContent(String(localized: "Voice Name")) {
                TextField(String(localized: "Voice name"), text: $voiceName)
                    .multilineTextAlignment(.trailing)
            }

            Picker(String(localized: "Media Resolution"), selection: $mediaResolution) {
                Text(String(localized: "Low")).tag("low")
                Text(String(localized: "Medium")).tag("medium")
                Text(String(localized: "High")).tag("high")
            }

            Picker(String(localized: "Reasoning Effort"), selection: $reasoningEffort) {
                Text(String(localized: "Minimal")).tag("minimal")
                Text(String(localized: "Low")).tag("low")
                Text(String(localized: "Medium")).tag("medium")
                Text(String(localized: "High")).tag("high")
            }
        } header: {
            Text(String(localized: "Voice"))
        }
    }

    // MARK: - Defaults

    private var defaultsSection: some View {
        Section {
            Button {
                showModelPicker = true
            } label: {
                LabeledContent(String(localized: "Provider / Model")) {
                    Text(defaultModelLabel)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Picker(String(localized: "Execution Target"), selection: $defaultExecutionTarget) {
                Text(String(localized: "Automatic")).tag("automatic")
                ForEach(coordinator.peers.filter { $0.status == .online }) { peer in
                    Text(peer.name ?? peer.subdomain).tag(peer.id)
                }
            }
        } header: {
            Text(String(localized: "Defaults"))
        }
        .sheet(isPresented: $showModelPicker) {
            SettingsModelPickerSheet(
                selectedProviderName: $defaultProviderName,
                selectedModelId: $defaultModelId,
                isPresented: $showModelPicker,
                peers: coordinator.peers
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private var defaultModelLabel: String {
        if defaultModelId.isEmpty {
            return String(localized: "Select model")
        }
        if defaultProviderName.isEmpty {
            return defaultModelId
        }
        return "\(defaultProviderName) / \(defaultModelId)"
    }

    // MARK: - Notifications

    private var notificationsSection: some View {
        Section {
            Toggle(String(localized: "Task Completions"), isOn: $notifyCompletions)
            Toggle(String(localized: "Task Failures"), isOn: $notifyFailures)
            Toggle(String(localized: "Agent Questions"), isOn: $notifyQuestions)
            Toggle(String(localized: "Permission Requests"), isOn: $notifyPermissions)
        } header: {
            Text(String(localized: "Notifications"))
        }
    }

    // MARK: - Incoming Calls

    private var incomingCallsSection: some View {
        Section {
            Toggle(String(localized: "Allow Incoming Calls"), isOn: $incomingCallsEnabled)

            if incomingCallsEnabled {
                Toggle(String(localized: "Agent Questions"), isOn: $callQuestion)
                Toggle(String(localized: "Permission Requests"), isOn: $callPermission)
                Toggle(String(localized: "Task Completions"), isOn: $callCompleted)
                Toggle(String(localized: "Task Failures"), isOn: $callFailed)
                Toggle(String(localized: "Plan Reviews"), isOn: $callPlanReview)
                Toggle(String(localized: "Writeback Reviews"), isOn: $callWritebackReview)
            }
        } header: {
            Text(String(localized: "Incoming Calls"))
        }
        .animation(.default, value: incomingCallsEnabled)
    }

    // MARK: - Storage

    private var storageSection: some View {
        Section {
            LabeledContent(String(localized: "Cache Usage")) {
                Text(formattedCacheSize)
                    .foregroundStyle(.secondary)
            }

            Button(role: .destructive) {
                showClearCacheConfirmation = true
            } label: {
                Text(String(localized: "Clear Cache"))
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .alert(
                String(localized: "Clear Cache"),
                isPresented: $showClearCacheConfirmation
            ) {
                Button(String(localized: "Cancel"), role: .cancel) {}
                Button(String(localized: "Clear"), role: .destructive) {
                    artifactCoordinator.clearCache(olderThan: 0)
                    cacheSize = Self.computeCacheSize()
                }
            } message: {
                Text(String(localized: "This will remove all cached session traces and output files."))
            }

            Picker(String(localized: "Trace Retention"), selection: $traceRetentionDays) {
                Text(String(localized: "Keep All")).tag(0)
                Text(String(localized: "7 Days")).tag(7)
                Text(String(localized: "30 Days")).tag(30)
                Text(String(localized: "90 Days")).tag(90)
            }
        } header: {
            Text(String(localized: "Storage"))
        }
    }

    private var formattedCacheSize: String {
        ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file)
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            LabeledContent(String(localized: "Version")) {
                Text(Self.appVersionString)
                    .foregroundStyle(.secondary)
            }

            Link(String(localized: "Privacy Policy"),
                 destination: URL(string: "https://github.com/johnbean393/Hivecrew/blob/main/PRIVACY.md")!)
            Link(String(localized: "Terms of Service"),
                 destination: URL(string: "https://github.com/johnbean393/Hivecrew/blob/main/TERMS.md")!)
            Link(String(localized: "Support"),
                 destination: URL(string: "https://github.com/johnbean393/Hivecrew/issues")!)
        } header: {
            Text(String(localized: "About"))
        }
    }

    // MARK: - Helpers

    private static var appVersionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "–"
        return "\(version) (\(build))"
    }

    private static func computeCacheSize() -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        let directories = [
            AppPaths.sessionsDirectory,
            ArtifactImportCoordinator.outputsDirectory,
        ]
        for directory in directories {
            total += Self.directorySize(at: directory, fileManager: fm)
        }
        return total
    }

    private static func directorySize(at url: URL, fileManager fm: FileManager) -> Int64 {
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }
}

// MARK: - Settings Model Picker Sheet

private struct SettingsModelPickerSheet: View {
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
            .navigationTitle(String(localized: "Default Model"))
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

        return Button {
            selectedProviderName = activeProviderName
            selectedModelId = modelId
            isPresented = false
        } label: {
            HStack(spacing: 12) {
                Text(modelId)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

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

#Preview {
    NavigationStack {
        SettingsView()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .environmentObject(RemoteAccessAuthManager())
            .environmentObject(HivelinkClusterCoordinator())
            .environmentObject(ArtifactImportCoordinator())
    }
}
