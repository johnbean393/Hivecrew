//
//  DeveloperSettingsView.swift
//  Hivecrew
//
//  Developer settings tab - developer mode toggle and manual VM creation
//

import SwiftUI
import TipKit
import HivecrewLLM
import HivecrewShared

/// Developer settings tab - enable developer mode and manually create/manage VMs
struct DeveloperSettingsView: View {
    @EnvironmentObject var vmService: VMServiceClient
    
    @AppStorage("developerModeEnabled") private var developerModeEnabled = false
    @AppStorage("developerVMIds") private var developerVMIdsData: Data = Data()
    @AppStorage(VoiceAvailability.developerVoiceSessionCaptureKey) private var voiceSessionCaptureEnabled = false
    
    @State private var templates: [TemplateInfo] = []
    @State private var isLoadingTemplates = false
    @State private var selectedTemplateId: String = ""
    @State private var newVMName: String = ""
    @State private var isCreatingVM = false
    @State private var createError: String?
    @State private var showingDeleteConfirmation = false
    @State private var vmToDelete: VMInfo?
    @State private var isStartingVM: String?
    @State private var isStoppingVM: String?

    @State private var proxyEnabled = false
    @State private var proxyBaseURL = ""
    @State private var proxyToken = ""
    @State private var proxyStatusMessage: String?
    
    // Tips
    private let developerModeTip = DeveloperModeTip()
    
    /// Computed property to get developer VM IDs
    private var developerVMIds: Set<String> {
        guard let decoded = try? JSONDecoder().decode(Set<String>.self, from: developerVMIdsData) else {
            return []
        }
        return decoded
    }
    
    /// Add a VM ID to the developer VMs set
    private func addDeveloperVMId(_ id: String) {
        var ids = developerVMIds
        ids.insert(id)
        if let encoded = try? JSONEncoder().encode(ids) {
            developerVMIdsData = encoded
        }
    }
    
    /// Remove a VM ID from the developer VMs set
    private func removeDeveloperVMId(_ id: String) {
        var ids = developerVMIds
        ids.remove(id)
        if let encoded = try? JSONEncoder().encode(ids) {
            developerVMIdsData = encoded
        }
    }
    
    /// Developer VMs (filtered from all VMs)
    private var developerVMs: [VMInfo] {
        vmService.vms.filter { developerVMIds.contains($0.id) }
    }

    private var canStartAdditionalVMs: Bool {
        vmRuntime.runningVMs.count < VMConcurrencyPolicy.hostMaxRunningVMs
    }
    
    /// Reference to the app's VM runtime
    private var vmRuntime: AppVMRuntime { AppVMRuntime.shared }
    
    var body: some View {
        Form {
            developerModeSection
            
            if developerModeEnabled {
                codexProxySection
                createVMSection
                developerVMsSection
                audioSection
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            TipStore.shared.donateDeveloperSettingsOpened()
        }
        .task {
            if developerModeEnabled {
                await loadTemplates()
            }
        }
        .onChange(of: developerModeEnabled) { _, newValue in
            if newValue {
                Task { await loadTemplates() }
            }
        }
        .alert("Delete Developer VM?", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                vmToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let vm = vmToDelete {
                    Task { await deleteVM(vm) }
                }
            }
        } message: {
            if let vm = vmToDelete {
                Text("Are you sure you want to delete \"\(vm.name)\"? This action cannot be undone.")
            }
        }
    }
    
    // MARK: - Developer Mode Section
    
    private var developerModeSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Enable Developer Mode", isOn: $developerModeEnabled)
                    .toggleStyle(.switch)
                    .popoverTip(developerModeTip, arrowEdge: .trailing)
                
                Text("Developer mode allows you to manually create and manage persistent VMs for testing and development. These VMs will not be used by agent tasks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Developer Mode")
        }
    }
    
    // MARK: - Audio Section
    private var audioSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Save Voice Session Audio + Logs", isOn: $voiceSessionCaptureEnabled)
                    .toggleStyle(.switch)
                
                Text("When enabled, Gemini and OpenAI voice sessions are captured under ~/Library/Application Support/Hivecrew/Debug/Voice Mode/Sessions for debugging.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Audio")
        }
    }
    
    // MARK: - Create VM Section
    
    private var createVMSection: some View {
        Section {
            if isLoadingTemplates {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading templates...")
                        .foregroundStyle(.secondary)
                }
            } else if templates.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No templates available")
                        .foregroundStyle(.secondary)
                    Text("Import a template in Settings → Environment before creating developer VMs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Picker("Template", selection: $selectedTemplateId) {
                    Text("Select a template...").tag("")
                    ForEach(templates) { template in
                        Text(template.name).tag(template.id)
                    }
                }
                
                if !selectedTemplateId.isEmpty {
                    selectedTemplateInfo
                }
                
                TextField("VM Name", text: $newVMName)
                    .textFieldStyle(.roundedBorder)
                
                HStack {
                    Button(action: createVM) {
                        if isCreatingVM {
                            ProgressView()
                                .scaleEffect(0.8)
                                .frame(width: 16, height: 16)
                        } else {
                            Image(systemName: "plus.circle")
                        }
                        Text("Create VM")
                    }
                    .disabled(selectedTemplateId.isEmpty || newVMName.isEmpty || isCreatingVM)
                    
                    Spacer()
                }
                
                if let error = createError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        } header: {
            Text("Create Developer VM")
        } footer: {
            Text("Developer VMs are persistent and count toward the \"Max Concurrent VMs\" limit when running.")
        }
    }
    
    @ViewBuilder
    private var selectedTemplateInfo: some View {
        if let template = templates.first(where: { $0.id == selectedTemplateId }) {
            HStack(spacing: 16) {
                Label("\(template.cpuCount) CPU", systemImage: "cpu")
                Label(template.memorySizeFormatted, systemImage: "memorychip")
                Label(template.diskSizeFormatted, systemImage: "internaldrive")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
    
    // MARK: - Developer VMs Section
    
    private var developerVMsSection: some View {
        Section {
            if developerVMs.isEmpty {
                Text("No developer VMs created yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(developerVMs) { vm in
                    developerVMRow(vm)
                }
            }
        } header: {
            Text("Developer VMs")
        }
    }
    
    private func developerVMRow(_ vm: VMInfo) -> some View {
        HStack {
            // Status indicator
            Image(systemName: statusIcon(for: vm))
                .foregroundStyle(statusColor(for: vm))
            
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.name)
                    .font(.body)
                
                Text(statusText(for: vm))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // Action buttons
            HStack(spacing: 8) {
                // Start/Stop button
                if isRunning(vm) {
                    Button(action: { Task { await stopVM(vm) } }) {
                        if isStoppingVM == vm.id {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 16, height: 16)
                        } else {
                            Image(systemName: "stop.fill")
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
                    .disabled(isStoppingVM == vm.id)
                    .help("Stop VM")
                } else {
                    Button(action: { Task { await startVM(vm) } }) {
                        if isStartingVM == vm.id {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 16, height: 16)
                        } else {
                            Image(systemName: "play.fill")
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.green)
                    .disabled(isStartingVM == vm.id || !canStartAdditionalVMs)
                    .help(canStartAdditionalVMs ? "Start VM" : "macOS only allows 2 running VMs at once")
                }
                
                // Delete button
                Button(action: {
                    vmToDelete = vm
                    showingDeleteConfirmation = true
                }) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .disabled(isRunning(vm))
                .help(isRunning(vm) ? "Stop the VM before deleting" : "Delete VM")
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Show in Finder") {
                showInFinder(vm)
            }
        }
    }
    
    // MARK: - Codex Proxy Section

    private var codexProxySection: some View {
        Section {
            Toggle("Enable Codex Proxy", isOn: $proxyEnabled)
                .toggleStyle(.switch)
                .onChange(of: proxyEnabled) { _, newValue in
                    saveProxyConfig()
                }

            TextField("Proxy Base URL", text: $proxyBaseURL, prompt: Text("https://your-proxy.example.com"))
                .textFieldStyle(.roundedBorder)
                .disabled(!proxyEnabled)

            SecureField("Proxy Token", text: $proxyToken, prompt: Text("X-Proxy-Token value"))
                .textFieldStyle(.roundedBorder)
                .disabled(!proxyEnabled)

            HStack {
                Button("Save") {
                    saveProxyConfig()
                    proxyStatusMessage = "Proxy configuration saved."
                }
                .disabled(!proxyEnabled || proxyBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || proxyToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Clear", role: .destructive) {
                    CodexProxyConfigStore.delete()
                    proxyEnabled = false
                    proxyBaseURL = ""
                    proxyToken = ""
                    proxyStatusMessage = "Proxy configuration cleared."
                }

                Spacer()
            }

            if let message = proxyStatusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Routes Codex API, OAuth token refresh, and voice realtime traffic through a custom proxy server. The browser-based OAuth sign-in still goes directly to OpenAI.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Codex Proxy")
        }
        .onAppear {
            loadProxyConfig()
        }
    }

    private func loadProxyConfig() {
        if let config = CodexProxyConfigStore.retrieve() {
            proxyEnabled = config.enabled
            proxyBaseURL = config.baseURL
            proxyToken = config.token
        }
    }

    private func saveProxyConfig() {
        let config = CodexProxyConfig(
            enabled: proxyEnabled,
            baseURL: proxyBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            token: proxyToken.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        CodexProxyConfigStore.store(config)
    }

    // MARK: - VM Status Helpers
    
    private func isRunning(_ vm: VMInfo) -> Bool {
        vmRuntime.getVM(id: vm.id) != nil
    }
    
    private func statusIcon(for vm: VMInfo) -> String {
        if isRunning(vm) {
            return "circle.fill"
        }
        return "circle"
    }
    
    private func statusColor(for vm: VMInfo) -> Color {
        if isRunning(vm) {
            return .green
        }
        return .secondary
    }
    
    private func statusText(for vm: VMInfo) -> String {
        if isRunning(vm) {
            return "Running"
        }
        return "Stopped"
    }
    
    // MARK: - Actions
    
    private func loadTemplates() async {
        isLoadingTemplates = true
        
        do {
            templates = try await vmService.listTemplates()
            
            // Auto-select first template if none selected
            if selectedTemplateId.isEmpty && !templates.isEmpty {
                selectedTemplateId = templates[0].id
            }
        } catch {
            print("DeveloperSettingsView: Failed to load templates: \(error)")
        }
        
        isLoadingTemplates = false
    }
    
    private func createVM() {
        guard !selectedTemplateId.isEmpty, !newVMName.isEmpty else { return }
        
        isCreatingVM = true
        createError = nil
        
        Task {
            do {
                let vmId = try await vmService.createVMFromTemplate(
                    templateId: selectedTemplateId,
                    name: newVMName
                )
                
                // Add to developer VM IDs
                addDeveloperVMId(vmId)
                
                // Clear the form
                newVMName = ""
                
                // Refresh VMs to show the new one
                await vmService.refreshVMs()
                
                print("DeveloperSettingsView: Created developer VM '\(vmId)'")
            } catch {
                createError = error.localizedDescription
                print("DeveloperSettingsView: Failed to create VM: \(error)")
            }
            
            isCreatingVM = false
        }
    }
    
    private func startVM(_ vm: VMInfo) async {
        guard canStartAdditionalVMs else {
            print("DeveloperSettingsView: Refusing to start VM '\(vm.name)' because the host limit is already reached")
            return
        }

        isStartingVM = vm.id
        
        do {
            try await vmRuntime.startVM(id: vm.id)
            await vmService.refreshVMs()
            print("DeveloperSettingsView: Started developer VM '\(vm.name)'")
        } catch {
            print("DeveloperSettingsView: Failed to start VM: \(error)")
        }
        
        isStartingVM = nil
    }
    
    private func stopVM(_ vm: VMInfo) async {
        isStoppingVM = vm.id
        
        do {
            try await vmRuntime.stopVM(id: vm.id, force: false)
            await vmService.refreshVMs()
            print("DeveloperSettingsView: Stopped developer VM '\(vm.name)'")
        } catch {
            print("DeveloperSettingsView: Failed to stop VM: \(error)")
        }
        
        isStoppingVM = nil
    }
    
    private func deleteVM(_ vm: VMInfo) async {
        // Make sure it's stopped first
        if isRunning(vm) {
            try? await vmRuntime.stopVM(id: vm.id, force: true)
        }
        
        do {
            try await vmService.deleteVM(id: vm.id)
            
            // Remove from developer VM IDs
            removeDeveloperVMId(vm.id)
            
            // Refresh VMs
            await vmService.refreshVMs()
            
            print("DeveloperSettingsView: Deleted developer VM '\(vm.name)'")
        } catch {
            print("DeveloperSettingsView: Failed to delete VM: \(error)")
        }
        
        vmToDelete = nil
    }

    /// Function to show the VM directory in Finder
    private func showInFinder(_ vm: VMInfo) {
        NSWorkspace.shared.open(AppPaths.vmDirectory.appendingPathComponent(vm.id))
    }
}

#Preview {
    DeveloperSettingsView()
        .environmentObject(VMServiceClient.shared)
        .frame(width: 500, height: 600)
}
