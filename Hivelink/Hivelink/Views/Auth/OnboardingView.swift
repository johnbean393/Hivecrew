//
//  OnboardingView.swift
//  Hivelink
//

import HivecrewAPIModels
import HivecrewCore
import HivecrewShared
import SwiftUI

private enum AuthRoute: Hashable {
    case otp
}

private enum HivelinkOnboardingStep: Int, CaseIterable {
    case models = 0
    case voice = 1

    var title: String {
        switch self {
        case .models:
            return "Models"
        case .voice:
            return "Voice"
        }
    }
}

struct OnboardingView: View {
    @EnvironmentObject private var authManager: RemoteAccessAuthManager
    @EnvironmentObject private var clusterCoordinator: HivelinkClusterCoordinator
    @EnvironmentObject private var voiceOrchestrator: HivelinkVoiceOrchestrator

    @AppStorage("hivelink.hasCompletedOnboarding") private var hasCompletedOnboarding = false

    @State private var path = NavigationPath()
    @State private var currentStep: HivelinkOnboardingStep = .models
    @State private var modelConfigured = false
    @State private var voiceConfigured = false

    var body: some View {
        Group {
            if authManager.isAuthenticated {
                postAuthWizard
            } else {
                authFlow
            }
        }
        .onAppear {
            syncPostAuthState()
        }
        .onChange(of: authManager.isAuthenticated) { _, _ in
            syncPostAuthState()
        }
    }

    private var authFlow: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 32) {
                    brandingHeader
                    EmailEntryView {
                        path.append(AuthRoute.otp)
                    }
                }
                .padding()
            }
            .navigationTitle("Hivelink")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: AuthRoute.self) { _ in
                OTPVerificationView()
            }
        }
    }

    private var postAuthWizard: some View {
        VStack(spacing: 0) {
            progressIndicator
                .padding(.top, 24)
                .padding(.bottom, 16)

            Divider()

            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            navigationButtons
                .padding(20)
        }
        .onAppear {
            syncPostAuthState()
        }
    }

    private var brandingHeader: some View {
        VStack(spacing: 12) {
            Image(systemName: "hexagon.fill")
                .font(.system(size: 56))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
            Text("Hivelink")
                .font(.largeTitle.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var progressIndicator: some View {
        HStack(spacing: 8) {
            ForEach(HivelinkOnboardingStep.allCases, id: \.rawValue) { step in
                HStack(spacing: 8) {
                    Circle()
                        .fill(step.rawValue <= currentStep.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 10, height: 10)

                    Text(step.title)
                        .font(.caption)
                        .fontWeight(step == currentStep ? .semibold : .regular)
                        .foregroundStyle(step.rawValue <= currentStep.rawValue ? .primary : .secondary)

                    if step != HivelinkOnboardingStep.allCases.last {
                        Rectangle()
                            .fill(step.rawValue < currentStep.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 30, height: 2)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case .models:
            HivelinkOnboardingModelStep(isConfigured: $modelConfigured)
                .environmentObject(clusterCoordinator)
        case .voice:
            VoiceSetupFlowView(
                title: "Configure Voice Provider",
                subtitle: "Choose Google Gemini or OpenAI. For OpenAI, use either an API key or ChatGPT OAuth.",
                onConfigurationChange: { isConfigured in
                    voiceConfigured = isConfigured
                }
            )
            .environmentObject(voiceOrchestrator)
        }
    }

    private var navigationButtons: some View {
        HStack {
            if currentStep != .models {
                Button("Back") {
                    goBack()
                }
            }

            Spacer()

            Button(currentStep == .voice ? "Get Started" : "Continue") {
                goNext()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canContinue)
        }
    }

    private var canContinue: Bool {
        switch currentStep {
        case .models:
            return modelConfigured
        case .voice:
            return voiceConfigured
        }
    }

    private var hasStoredModelSelection: Bool {
        let defaults = UserDefaults.standard
        let provider = defaults.string(forKey: "hivelink.lastProviderName")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = defaults.string(forKey: "hivelink.lastModelId")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !provider.isEmpty && !model.isEmpty
    }

    private func syncPostAuthState() {
        guard authManager.isAuthenticated else { return }

        modelConfigured = hasStoredModelSelection
        voiceConfigured = voiceOrchestrator.isVoiceConfigured

        if currentStep != .voice {
            currentStep = .models
        }
    }

    private func goNext() {
        switch currentStep {
        case .models:
            currentStep = .voice
        case .voice:
            completeOnboarding()
        }
    }

    private func goBack() {
        switch currentStep {
        case .models:
            break
        case .voice:
            currentStep = .models
        }
    }

    private func completeOnboarding() {
        hasCompletedOnboarding = true
    }
}

private struct HivelinkOnboardingModelStep: View {
    @EnvironmentObject private var clusterCoordinator: HivelinkClusterCoordinator

    @Binding var isConfigured: Bool

    @AppStorage("hivelink.lastProviderName") private var storedProviderName = ""
    @AppStorage("hivelink.lastModelId") private var storedModelId = ""

    @State private var isRefreshing = false

    private var onlinePeers: [DiscoveredClusterPeer] {
        clusterCoordinator.peers.filter { $0.status == .online }
    }

    private var providerNames: [String] {
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
        if providerNames.contains(storedProviderName) {
            return storedProviderName
        }
        return providerNames.first ?? storedProviderName
    }

    private var modelsForActiveProvider: [String] {
        models(for: activeProviderName)
    }

    private var peerSignature: String {
        onlinePeers.map { peer in
            let providers = peer.providers
                .map { "\($0.providerName):\($0.modelIds.joined(separator: ","))" }
                .joined(separator: ";")
            return "\(peer.id)|\(providers)"
        }
        .joined(separator: "||")
    }

    var body: some View {
        VStack(spacing: 24) {
            OnboardingStepHeaderView(
                systemImage: "bolt.circle",
                tint: .orange,
                title: "Choose Default Task Model",
                subtitle: "Select the provider and model Hivelink should use from your connected execution nodes."
            )

            if onlinePeers.isEmpty {
                emptyState
            } else {
                formSection
            }

            Spacer()

            if isConfigured {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Task model configured")
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 8)
            } else {
                Text("Select a provider and model to continue.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.bottom, 8)
            }
        }
        .padding()
        .onAppear {
            syncSelectionFromPeers()
            refreshConfiguredState()
            if onlinePeers.isEmpty {
                refreshPeers()
            }
        }
        .onChange(of: peerSignature) { _, _ in
            syncSelectionFromPeers()
            refreshConfiguredState()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            ContentUnavailableView(
                "No connected execution nodes",
                systemImage: "desktopcomputer.trianglebadge.exclamationmark",
                description: Text("Bring a Hivecrew execution node online, then refresh to load its available models.")
            )

            Button {
                refreshPeers()
            } label: {
                HStack(spacing: 8) {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Refresh Nodes")
                }
            }
            .buttonStyle(.bordered)
            .disabled(isRefreshing)
        }
        .padding(.horizontal, 24)
    }

    private var formSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Provider")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker(
                    "Provider",
                    selection: Binding(
                        get: { activeProviderName },
                        set: { newValue in
                            storedProviderName = newValue
                            let models = models(for: newValue)
                            if !models.contains(storedModelId) {
                                storedModelId = models.first ?? ""
                            }
                            refreshConfiguredState()
                        }
                    )
                ) {
                    ForEach(providerNames, id: \.self) { providerName in
                        Text(providerName).tag(providerName)
                    }
                }
                .pickerStyle(.menu)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Model")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker(
                    "Model",
                    selection: Binding(
                        get: {
                            if modelsForActiveProvider.contains(storedModelId) {
                                return storedModelId
                            }
                            return modelsForActiveProvider.first ?? ""
                        },
                        set: { newValue in
                            storedModelId = newValue
                            refreshConfiguredState()
                        }
                    )
                ) {
                    ForEach(modelsForActiveProvider, id: \.self) { modelId in
                        Text(modelId).tag(modelId)
                    }
                }
                .pickerStyle(.menu)
            }

            Text("This becomes the default provider/model for new tasks and voice-created tasks in Hivelink.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Button {
                refreshPeers()
            } label: {
                HStack(spacing: 8) {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Refresh Nodes")
                }
            }
            .buttonStyle(.bordered)
            .disabled(isRefreshing)
        }
        .padding(.horizontal, 24)
    }

    private func models(for providerName: String) -> [String] {
        guard !providerName.isEmpty else { return [] }

        var seen = Set<String>()
        var result: [String] = []
        for peer in onlinePeers {
            for provider in peer.providers where provider.providerName == providerName {
                for modelId in provider.modelIds where !seen.contains(modelId) {
                    seen.insert(modelId)
                    result.append(modelId)
                }
            }
        }
        return result
    }

    private func syncSelectionFromPeers() {
        guard !providerNames.isEmpty else {
            storedProviderName = ""
            storedModelId = ""
            return
        }

        if !providerNames.contains(storedProviderName) {
            storedProviderName = providerNames.first ?? ""
        }

        let validModels = models(for: storedProviderName)
        if !validModels.contains(storedModelId) {
            storedModelId = validModels.first ?? ""
        }
    }

    private func refreshConfiguredState() {
        let providerName = storedProviderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelId = storedModelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !providerName.isEmpty,
              !modelId.isEmpty,
              providerNames.contains(providerName) else {
            isConfigured = false
            return
        }

        isConfigured = models(for: providerName).contains(modelId)
    }

    private func refreshPeers() {
        isRefreshing = true
        Task {
            await clusterCoordinator.refreshPeers()
            await MainActor.run {
                isRefreshing = false
                syncSelectionFromPeers()
                refreshConfiguredState()
            }
        }
    }
}

#Preview {
    OnboardingView()
        .environmentObject(RemoteAccessAuthManager())
        .environmentObject(HivelinkClusterCoordinator())
        .environmentObject(HivelinkVoiceOrchestrator())
}
