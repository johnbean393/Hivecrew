//
//  APISettingsView.swift
//  Hivecrew
//
//  Settings view for the REST API server and remote access
//

import SwiftUI
import TipKit
import HivecrewAPI
import CoreImage.CIFilterBuiltins

/// Settings view for the Hivecrew REST API server and remote access
struct APISettingsView: View {
    
    // MARK: - API Server State
    
    @AppStorage("apiServerEnabled") private var apiServerEnabled = false
    @AppStorage("apiServerPort") private var apiServerPort = 5482
    @AppStorage("apiMaxFileSize") private var apiMaxFileSize = 100 // MB
    @AppStorage("apiMaxTotalUploadSize") private var apiMaxTotalUploadSize = 500 // MB
    
    private var serverStatus: APIServerStatus { APIServerStatus.shared }
    
    @State private var apiKey: String = ""
    @State private var showAPIKey = false
    @State private var showRegenerateConfirmation = false
    @State private var copyFeedback = false
    @State private var restartTask: Task<Void, Never>?
    
    // Tips
    private let apiIntegrationTip = APIIntegrationTip()
    
    // MARK: - Device Auth State
    
    @ObservedObject private var deviceAuth = DeviceAuthService.shared
    @State private var showRevokeConfirmation = false
    @State private var deviceToRevoke: APIDeviceSession?
    @State private var deviceToRename: APIDeviceSession?
    @State private var renameText = ""
    @State private var showRenameAlert = false
    
    // MARK: - Remote Access State
    
    @ObservedObject private var remoteStatus = RemoteAccessStatus.shared
    
    @State private var emailInput = ""
    @State private var otpInput = ""
    @State private var isRemoteLoading = false
    @State private var showRemoveConfirmation = false
    @State private var urlCopyFeedback = false
    
    // MARK: - Body
    
    var body: some View {
        Form {
            // Server Section
            Section {
                Toggle("Enable API Server", isOn: $apiServerEnabled)
                    .onChange(of: apiServerEnabled) { _, newValue in
                        if newValue {
                            APIServerManager.shared.startIfEnabled()
                        } else {
                            APIServerManager.shared.stop()
                        }
                    }
                    .popoverTip(apiIntegrationTip, arrowEdge: .trailing)
                
                HStack {
                    Text("Port")
                    Spacer()
                    TextField("", value: $apiServerPort, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                        .onChange(of: apiServerPort) { _, _ in
                            if apiServerEnabled {
                                restartServerDebounced()
                            }
                        }
                }
                
                if apiServerEnabled {
                    HStack {
                        Text("Status")
                        Spacer()
                        HStack(spacing: 6) {
                            Circle()
                                .fill(serverStatus.state.statusColor)
                                .frame(width: 8, height: 8)
                            Text(serverStatus.state.statusText)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    if serverStatus.state.isRunning {
                        HStack {
                            Text("Base URL")
                            Spacer()
                            Text(baseURL)
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(baseURL, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help("Copy base URL")
                        }
                        
                        HStack {
                            Text("Web UI URL")
                            Spacer()
                            Text(webUiURL)
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(webUiURL, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help("Copy Web UI URL")
                        }
                    }
                }
            } header: {
                Text("Server")
            }
            
            // Authentication Section
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("API Key")
                        Spacer()
                        if copyFeedback {
                            Text("Copied!")
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    }
                    
                    HStack {
                        if showAPIKey {
                            Text(apiKey.isEmpty ? "Not generated" : apiKey)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        } else {
                            Text(apiKey.isEmpty ? "Not generated" : maskAPIKey(apiKey))
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        Button {
                            showAPIKey.toggle()
                        } label: {
                            Image(systemName: showAPIKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(showAPIKey ? "Hide API key" : "Show API key")
                        
                        Button {
                            copyAPIKeyToClipboard()
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .disabled(apiKey.isEmpty)
                        .help("Copy API key to clipboard")
                    }
                    
                    HStack {
                        if apiKey.isEmpty {
                            Button("Generate API Key") {
                                generateAPIKey()
                            }
                        } else {
                            Button("Regenerate") {
                                showRegenerateConfirmation = true
                            }
                            .foregroundColor(.orange)
                        }
                    }
                }
            } header: {
                Text("Authentication")
            }
            
            // Authorized Devices Section
            Section {
                if deviceAuth.authorizedDevices.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No devices authorized")
                            .foregroundColor(.secondary)
                        Text("Devices that connect via the web UI pairing flow will appear here.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    ForEach(deviceAuth.authorizedDevices) { device in
                        HStack(spacing: 12) {
                            Image(systemName: deviceTypeIcon(device.deviceType))
                                .font(.title2)
                                .foregroundColor(.secondary)
                                .frame(width: 28)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                    .font(.body)
                                Text("Authorized \(formatDeviceDate(device.authorizedAt))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Button {
                                deviceToRename = device
                                renameText = device.name
                                showRenameAlert = true
                            } label: {
                                Image(systemName: "pencil")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Rename this device")
                            
                            Button {
                                deviceToRevoke = device
                                showRevokeConfirmation = true
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.borderless)
                            .help("Revoke this device")
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                Text("Authorized Devices")
            }
            
            // File Upload Limits Section
            Section {
                HStack {
                    Text("Max file size")
                    Spacer()
                    TextField("", value: $apiMaxFileSize, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                    Text("MB")
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Text("Max total upload per task")
                    Spacer()
                    TextField("", value: $apiMaxTotalUploadSize, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                    Text("MB")
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("File Upload Limits")
            }
            
            // Remote Access Section
            Section {
                switch remoteStatus.state {
                case .notConfigured:
                    remoteNotConfiguredView
                    
                case .authenticating, .awaitingOTP:
                    remoteEmailVerificationView
                    
                case .provisioning:
                    remoteProvisioningView
                    
                case .connecting:
                    remoteConnectingView
                    
                case .connected:
                    remoteConnectedView
                    
                case .disconnected:
                    remoteDisconnectedView
                    
                case .failed:
                    remoteFailedView
                }
                
                // Show error if present
                if let error = remoteStatus.errorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.caption)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Remote Access")
            } footer: {
                if remoteStatus.state == .notConfigured {
                    Text("Access your Hivecrew instance from anywhere via a secure Cloudflare Tunnel. Requires email verification.")
                }
            }
            
            // Usage Section
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Example: Create a task")
                        .font(.headline)
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(exampleCurlCommand)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .background(Color(NSColor.textBackgroundColor))
                            .cornerRadius(4)
                    }
                    
                    Button("Copy Example") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(exampleCurlCommand, forType: .string)
                    }
                }
            } header: {
                Text("Usage")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            loadAPIKey()
            // Refresh server status to sync with actual state
            APIServerManager.shared.refreshStatus()
            // Refresh authorized devices
            Task { await deviceAuth.refreshDevices() }
            // Track API settings opened for tips
            TipStore.shared.donateAPISettingsOpened()
        }
        .alert("Regenerate API Key?", isPresented: $showRegenerateConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Regenerate", role: .destructive) {
                regenerateAPIKey()
            }
        } message: {
            Text("This will invalidate the current API key. Any applications using the old key will stop working.")
        }
        .alert("Revoke Device?", isPresented: $showRevokeConfirmation) {
            Button("Cancel", role: .cancel) {
                deviceToRevoke = nil
            }
            Button("Revoke", role: .destructive) {
                if let device = deviceToRevoke {
                    Task { await deviceAuth.revokeDevice(id: device.id) }
                }
                deviceToRevoke = nil
            }
        } message: {
            if let device = deviceToRevoke {
                Text("This will disconnect \"\(device.name)\" and require it to pair again.")
            }
        }
        .alert("Rename Device", isPresented: $showRenameAlert) {
            TextField("Device name", text: $renameText)
            Button("Cancel", role: .cancel) {
                deviceToRename = nil
                renameText = ""
            }
            Button("Save") {
                if let device = deviceToRename {
                    let newName = renameText
                    Task { await deviceAuth.renameDevice(id: device.id, name: newName) }
                }
                deviceToRename = nil
                renameText = ""
            }
        } message: {
            Text("Enter a new name for this device.")
        }
    }
    
    // MARK: - Remote Access State Views
    
    private var remoteNotConfiguredView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Enable remote access to control Hivecrew from your phone or any device.")
                .font(.callout)
                .foregroundColor(.secondary)
            
            Button("Set Up Remote Access") {
                remoteStatus.update(state: .awaitingOTP)
                self.apiServerEnabled = true
            }
        }
    }
    
    private var remoteEmailVerificationView: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Email input row
            HStack {
                Text("Email")
                    .frame(width: 50, alignment: .leading)
                TextField("", text: $emailInput)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.emailAddress)
                    .disabled(isRemoteLoading || remoteStatus.state == .authenticating)
                    .onSubmit {
                        if remoteStatus.state == .awaitingOTP && !emailInput.isEmpty && otpInput.isEmpty {
                            sendOTP()
                        }
                    }
                
                Button("Send Code") {
                    sendOTP()
                }
                .disabled(emailInput.isEmpty || isRemoteLoading)
            }
            
            // OTP input row (shown after email is submitted)
            if remoteStatus.state == .awaitingOTP && !emailInput.isEmpty {
                HStack {
                    Text("Code")
                        .frame(width: 50, alignment: .leading)
                    TextField("6-digit code", text: $otpInput)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.oneTimeCode)
                        .frame(maxWidth: 140)
                        .onSubmit {
                            if otpInput.count == 6 {
                                verifyOTP()
                            }
                        }
                    
                    Button("Verify") {
                        verifyOTP()
                    }
                    .disabled(otpInput.count != 6 || isRemoteLoading)
                    
                    Spacer()
                    
                    Button("Cancel") {
                        cancelRemoteSetup()
                    }
                    .foregroundColor(.secondary)
                }
                
                Text("Check your email for a 6-digit code.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            if isRemoteLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }
    
    private var remoteProvisioningView: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Creating your secure tunnel...")
                .foregroundColor(.secondary)
        }
    }
    
    private var remoteConnectingView: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Connecting tunnel...")
                .foregroundColor(.secondary)
        }
    }
    
    private var remoteConnectedView: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Status
            HStack {
                Text("Status")
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)
                    Text("Connected")
                        .foregroundColor(.secondary)
                }
            }
            
            // Remote URL
            if let url = remoteStatus.remoteURL {
                HStack {
                    Text("Remote URL")
                    Spacer()
                    Text(url + "/web")
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                    
                    if urlCopyFeedback {
                        Text("Copied!")
                            .font(.caption)
                            .foregroundColor(.green)
                    } else {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url + "/web", forType: .string)
                            urlCopyFeedback = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                urlCopyFeedback = false
                            }
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy remote URL")
                    }
                }
            }
            
            // QR Code
            if let url = remoteStatus.remoteURL {
                HStack {
                    Spacer()
                    qrCodeImage(for: url + "/web")
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 120, height: 120)
                        .padding(8)
                        .background(Color.white)
                        .cornerRadius(8)
                    Spacer()
                }
            }
            
            // Email
            if let email = remoteStatus.email {
                HStack {
                    Text("Account")
                    Spacer()
                    Text(email)
                        .foregroundColor(.secondary)
                }
            }
            
            // Actions
            HStack {
                Button("Disconnect") {
                    Task { await RemoteAccessManager.shared.disconnect() }
                }
                
                Spacer()
                
                Button("Remove Remote Access") {
                    showRemoveConfirmation = true
                }
                .foregroundColor(.red)
            }
        }
        .alert("Remove Remote Access?", isPresented: $showRemoveConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Remove", role: .destructive) {
                Task { await RemoteAccessManager.shared.remove() }
            }
        } message: {
            Text("This will delete your tunnel and remote URL. You can set it up again later, but the URL will change.")
        }
    }
    
    private var remoteDisconnectedView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Status")
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(.yellow)
                        .frame(width: 8, height: 8)
                    Text("Disconnected")
                        .foregroundColor(.secondary)
                }
            }
            
            if let subdomain = remoteStatus.subdomain {
                HStack {
                    Text("Remote URL")
                    Spacer()
                    Text("https://\(subdomain).hivecrew.org/web")
                        .foregroundColor(.secondary)
                }
            }
            
            HStack {
                Button("Reconnect") {
                    Task { await RemoteAccessManager.shared.reconnect() }
                }
                
                Spacer()
                
                Button("Remove Remote Access") {
                    showRemoveConfirmation = true
                }
                .foregroundColor(.red)
            }
        }
        .alert("Remove Remote Access?", isPresented: $showRemoveConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Remove", role: .destructive) {
                Task { await RemoteAccessManager.shared.remove() }
            }
        } message: {
            Text("This will delete your tunnel and remote URL. You can set it up again later, but the URL will change.")
        }
    }
    
    private var remoteFailedView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Status")
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                    Text("Error")
                        .foregroundColor(.secondary)
                }
            }
            
            HStack {
                if RemoteAccessKeychain.isConfigured {
                    Button("Retry") {
                        Task { await RemoteAccessManager.shared.reconnect() }
                    }
                    
                    Spacer()
                    
                    Button("Remove Remote Access") {
                        showRemoveConfirmation = true
                    }
                    .foregroundColor(.red)
                } else {
                    Button("Try Again") {
                        remoteStatus.update(state: .notConfigured)
                    }
                }
            }
        }
        .alert("Remove Remote Access?", isPresented: $showRemoveConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Remove", role: .destructive) {
                Task { await RemoteAccessManager.shared.remove() }
            }
        } message: {
            Text("This will delete your tunnel and remote URL.")
        }
    }
    
    // MARK: - API Server Helpers
    
    private var baseURL: String {
        let port = serverStatus.actualPort ?? apiServerPort
        return "http://localhost:\(port)/api/v1"
    }
    
    private var webUiURL: String {
        let port = serverStatus.actualPort ?? apiServerPort
        return "http://localhost:\(port)/web"
    }
    
    private var exampleCurlCommand: String {
        return """
        curl -X POST http://localhost:\(apiServerPort)/api/v1/tasks \\
          -H "Authorization: Bearer $HIVECREW_API_KEY" \\
          -H "Content-Type: application/json" \\
          -d '{"description": "Open Safari", "providerName": "OpenRouter", "modelId": "anthropic/claude-sonnet-4.5"}'
        """
    }
    
    private func maskAPIKey(_ key: String) -> String {
        guard key.count > 8 else { return String(repeating: "•", count: key.count) }
        let prefix = String(key.prefix(4))
        let suffix = String(key.suffix(4))
        let middle = String(repeating: "•", count: min(20, key.count - 8))
        return prefix + middle + suffix
    }
    
    private func loadAPIKey() {
        apiKey = APIKeyManager.retrieveAPIKey() ?? ""
    }
    
    private func generateAPIKey() {
        if let key = APIKeyManager.generateAndStoreAPIKey() {
            apiKey = key
            showAPIKey = true
            if apiServerEnabled {
                APIServerManager.shared.restart()
            }
        }
    }
    
    private func regenerateAPIKey() {
        if let key = APIKeyManager.regenerateAPIKey() {
            apiKey = key
            showAPIKey = true
            if apiServerEnabled {
                APIServerManager.shared.restart()
            }
        }
    }
    
    /// Debounced restart to avoid multiple restarts during rapid changes
    private func restartServerDebounced() {
        restartTask?.cancel()
        restartTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            if !Task.isCancelled {
                await MainActor.run {
                    APIServerManager.shared.restart()
                }
            }
        }
    }
    
    private func copyAPIKeyToClipboard() {
        guard !apiKey.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(apiKey, forType: .string)
        
        copyFeedback = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copyFeedback = false
        }
    }
    
    // MARK: - Remote Access Actions
    
    private func sendOTP() {
        guard !emailInput.isEmpty else { return }
        isRemoteLoading = true
        Task {
            await RemoteAccessManager.shared.requestOTP(email: emailInput)
            await MainActor.run { isRemoteLoading = false }
        }
    }
    
    private func verifyOTP() {
        guard otpInput.count == 6 else { return }
        isRemoteLoading = true
        Task {
            await RemoteAccessManager.shared.verifyOTP(email: emailInput, code: otpInput)
            await MainActor.run {
                isRemoteLoading = false
                otpInput = ""
            }
        }
    }
    
    private func cancelRemoteSetup() {
        emailInput = ""
        otpInput = ""
        isRemoteLoading = false
        remoteStatus.update(state: .notConfigured)
        remoteStatus.errorMessage = nil
    }
    
    // MARK: - Device Auth Helpers
    
    private func deviceTypeIcon(_ type: APIDeviceType) -> String {
        switch type {
        case .desktop: return "desktopcomputer"
        case .mobile: return "iphone"
        case .tablet: return "ipad"
        }
    }
    
    private func formatDeviceDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    
    // MARK: - QR Code Generation
    
    private func qrCodeImage(for string: String) -> Image {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        
        guard let outputImage = filter.outputImage else {
            return Image(systemName: "qrcode")
        }
        
        // Scale up the QR code for crisp rendering
        let transform = CGAffineTransform(scaleX: 10, y: 10)
        let scaledImage = outputImage.transformed(by: transform)
        
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
            return Image(systemName: "qrcode")
        }
        
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        return Image(nsImage: nsImage)
    }
}

#Preview {
    APISettingsView()
        .frame(width: 550, height: 500)
}
