//
//  SettingsView.swift
//  Hivelink
//

import HivecrewAPIModels
import HivecrewCore
import HivecrewShared
import HivecrewVoice
import SwiftData
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var authManager: RemoteAccessAuthManager
    @EnvironmentObject private var coordinator: HivelinkClusterCoordinator
    @EnvironmentObject private var artifactCoordinator: ArtifactImportCoordinator
    @EnvironmentObject private var taskService: HivelinkTaskService

    // MARK: - Voice

    @AppStorage("hivelink.voiceProvider") private var voiceProvider = "gemini"
    @AppStorage("hivelink.voiceApiKey") private var voiceApiKey = ""
    @AppStorage("hivelink.voiceName") private var voiceName = "Leda"
    @AppStorage("hivelink.mediaResolution") private var mediaResolution = "medium"
    @AppStorage("hivelink.reasoningEffort") private var reasoningEffort = "low"

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
    @AppStorage("incomingCall_planReview") private var callPlanReview = true
    @AppStorage("incomingCall_writebackReview") private var callWritebackReview = false

    // MARK: - Storage

    @AppStorage("hivelink.traceRetentionDays") private var traceRetentionDays = 0

    @State private var cacheSize: Int64 = 0
    @State private var showClearCacheConfirmation = false
    @State private var showSignOutError = false
    @State private var showDeleteAccountConfirmation = false
    @State private var showDeleteAccountError = false
    @State private var diagnosticsVersion = 0

    private var onlinePeerCount: Int {
        coordinator.peers.filter { $0.status == .online }.count
    }

    private var peerCount: Int {
        coordinator.peers.count
    }

    private var selectedVoiceProvider: HivelinkVoiceProvider {
        HivelinkVoiceProvider.from(voiceProvider)
    }

    private var availableVoiceOptions: [RealtimeVoiceOption] {
        HivelinkVoicePreferences.availableVoices(for: selectedVoiceProvider)
    }

    var body: some View {
        Form {
            accountSection
            voiceSection
            notificationsSection
            incomingCallsSection
            storageSection
            diagnosticsSection
            aboutSection
        }
        .task {
            syncVoiceSelection()
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
                Task {
                    await authManager.logout()
                    if authManager.errorMessage != nil {
                        showSignOutError = true
                    }
                }
            } label: {
                if authManager.isSigningOut {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    Text(String(localized: "Sign Out"))
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .disabled(authManager.isSigningOut || authManager.isDeletingAccount)

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
            String(localized: "Sign Out Failed"),
            isPresented: $showSignOutError
        ) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(authManager.errorMessage ?? String(localized: "Something went wrong while signing out."))
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
                    } else {
                        await taskService.wipeAllLocalData()
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
            Picker(
                String(localized: "Provider"),
                selection: Binding(
                    get: { voiceProvider },
                    set: { newValue in
                        let oldProvider = selectedVoiceProvider
                        HivelinkVoicePreferences.saveVoiceName(voiceName, for: oldProvider)

                        let newProvider = HivelinkVoiceProvider.from(newValue)
                        voiceProvider = newProvider.rawValue
                        voiceName = HivelinkVoicePreferences.restoredVoiceName(
                            for: newProvider,
                            currentVoiceName: voiceName
                        )
                    }
                )
            ) {
                ForEach(HivelinkVoiceProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider.rawValue)
                }
            }

            LabeledContent(String(localized: "API Key")) {
                SecureField(String(localized: "Enter API key"), text: $voiceApiKey)
                    .multilineTextAlignment(.trailing)
            }

            Picker(
                String(localized: "Voice"),
                selection: Binding(
                    get: {
                        HivelinkVoicePreferences.normalizedVoiceName(
                            voiceName,
                            for: selectedVoiceProvider
                        )
                    },
                    set: { newValue in
                        voiceName = HivelinkVoicePreferences.saveVoiceName(
                            newValue,
                            for: selectedVoiceProvider
                        )
                    }
                )
            ) {
                ForEach(availableVoiceOptions) { voice in
                    Text(voice.displayName).tag(voice.id)
                }
            }
            .pickerStyle(.menu)

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

    private func syncVoiceSelection() {
        let normalized = HivelinkVoicePreferences.normalizeStoredSelection(
            providerRawValue: voiceProvider,
            voiceName: voiceName
        )
        voiceProvider = normalized.provider.rawValue
        voiceName = normalized.voiceName
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

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        Section {
            if hasVoIPDiagnosticsLog {
                ShareLink(item: VoIPDiagnosticsLog.fileURL) {
                    Label("Export VoIP Diagnostics", systemImage: "square.and.arrow.up")
                }
            } else {
                LabeledContent("VoIP Diagnostics") {
                    Text("No log yet")
                        .foregroundStyle(.secondary)
                }
            }

            Button(role: .destructive) {
                VoIPDiagnosticsLog.clear()
                diagnosticsVersion += 1
            } label: {
                Text("Clear VoIP Diagnostics")
            }
            .disabled(!hasVoIPDiagnosticsLog)
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Use the VoIP diagnostics log to inspect PushKit and CallKit behavior when Hivelink is not attached to Xcode.")
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

    private var hasVoIPDiagnosticsLog: Bool {
        _ = diagnosticsVersion
        return FileManager.default.fileExists(atPath: VoIPDiagnosticsLog.fileURL.path)
    }
}

#Preview {
    let container = try! ModelContainer(for: TaskRecord.self)
    let coordinator = HivelinkClusterCoordinator()
    NavigationStack {
        SettingsView()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .environmentObject(RemoteAccessAuthManager())
            .environmentObject(coordinator)
            .environmentObject(ArtifactImportCoordinator())
            .environmentObject(
                HivelinkTaskService(
                    modelContext: ModelContext(container),
                    clusterCoordinator: coordinator,
                    remoteTaskIndex: RemoteTaskIndex()
                )
            )
    }
}
