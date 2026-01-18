//
//  CredentialsSettingsView.swift
//  Hivecrew
//
//  Settings view for managing stored authentication credentials
//

import SwiftUI
import UniformTypeIdentifiers
import LocalAuthentication

/// Credentials settings tab
struct CredentialsSettingsView: View {
    
    @ObservedObject private var credentialManager = CredentialManager.shared
    
    @State private var showingAddSheet = false
    @State private var showingImportPicker = false
    @State private var showingImportPreview = false
    @State private var credentialToEdit: StoredCredential?
    @State private var importedCredentials: [ImportPreviewCredential] = []
    @State private var importError: String?
    @State private var showingDeleteConfirmation = false
    @State private var credentialToDelete: StoredCredential?
    
    var body: some View {
        Form {
            credentialsSection
            importSection
        }
        .formStyle(.grouped)
        .padding()
        .sheet(isPresented: $showingAddSheet) {
            AddCredentialSheet(credentialManager: credentialManager)
        }
        .sheet(item: $credentialToEdit) { credential in
            EditCredentialSheet(credential: credential, credentialManager: credentialManager)
        }
        .sheet(isPresented: $showingImportPreview) {
            ImportPreviewSheet(
                credentials: $importedCredentials,
                credentialManager: credentialManager,
                onDismiss: { showingImportPreview = false }
            )
        }
        .fileImporter(
            isPresented: $showingImportPicker,
            allowedContentTypes: [UTType.commaSeparatedText],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .alert("Delete Credential", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                if let credential = credentialToDelete {
                    try? credentialManager.deleteCredential(id: credential.id)
                }
            }
        } message: {
            if let credential = credentialToDelete {
                Text("Are you sure you want to delete '\(credential.displayName)'? This cannot be undone.")
            }
        }
    }
    
    // MARK: - Credentials Section
    
    private var credentialsSection: some View {
        Section {
            if credentialManager.credentials.isEmpty {
                Text("No credentials stored")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                ForEach(credentialManager.credentials) { credential in
                    CredentialRow(
                        credential: credential,
                        onEdit: {
                            credentialToEdit = credential
                        },
                        onDelete: {
                            credentialToDelete = credential
                            showingDeleteConfirmation = true
                        }
                    )
                }
            }
        } header: {
            HStack {
                Text("Stored Credentials")
                Spacer()
                Button {
                    showingAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
            }
        } footer: {
            Text("Credentials are stored securely in macOS Keychain. The agent uses UUID tokens to reference them - real passwords are never sent to the AI provider.")
        }
    }
    
    // MARK: - Import Section
    
    private var importSection: some View {
        Section("Import") {
            Group {
                Button {
                    showingImportPicker = true
                } label: {
                    Label("Import from CSV...", systemImage: "square.and.arrow.down")
                }
                
                if let error = importError {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
        }
    }
    
    // MARK: - File Import
    
    private func handleFileImport(_ result: Result<[URL], Error>) {
        importError = nil
        
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            
            // Start accessing the security-scoped resource
            guard url.startAccessingSecurityScopedResource() else {
                importError = "Unable to access the selected file"
                return
            }
            
            defer { url.stopAccessingSecurityScopedResource() }
            
            do {
                let contents = try String(contentsOf: url, encoding: .utf8)
                let parsed = parseCSV(contents)
                
                if parsed.isEmpty {
                    importError = "No valid credentials found in CSV file"
                } else {
                    importedCredentials = parsed
                    showingImportPreview = true
                }
            } catch {
                importError = "Failed to read file: \(error.localizedDescription)"
            }
            
        case .failure(let error):
            importError = "Import failed: \(error.localizedDescription)"
        }
    }
    
    private func parseCSV(_ contents: String) -> [ImportPreviewCredential] {
        var results: [ImportPreviewCredential] = []
        
        let lines = contents.components(separatedBy: .newlines)
        guard lines.count > 1 else { return [] }
        
        // Parse header
        let headerLine = lines[0]
        let headers = parseCSVLine(headerLine).map { $0.lowercased() }
        
        // Find column indices
        let nameColumns = ["name", "title", "url", "website", "login_uri"]
        let usernameColumns = ["username", "login_username", "email", "user"]
        let passwordColumns = ["password", "login_password", "pass"]
        
        let nameIndex = headers.firstIndex { nameColumns.contains($0) }
        let usernameIndex = headers.firstIndex { usernameColumns.contains($0) }
        let passwordIndex = headers.firstIndex { passwordColumns.contains($0) }
        
        // Parse data rows
        for i in 1..<lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            
            let values = parseCSVLine(line)
            
            let name = nameIndex.flatMap { $0 < values.count ? values[$0] : nil } ?? "Unnamed"
            let username = usernameIndex.flatMap { $0 < values.count ? values[$0] : nil }
            let password = passwordIndex.flatMap { $0 < values.count ? values[$0] : nil } ?? ""
            
            if !password.isEmpty {
                results.append(ImportPreviewCredential(
                    displayName: name,
                    username: username,
                    password: password,
                    selected: true
                ))
            }
        }
        
        return results
    }
    
    private func parseCSVLine(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        
        for char in line {
            if char == "\"" {
                inQuotes.toggle()
            } else if char == "," && !inQuotes {
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(char)
            }
        }
        
        result.append(current.trimmingCharacters(in: .whitespaces))
        return result
    }
}

// MARK: - Credential Row

private struct CredentialRow: View {
    let credential: StoredCredential
    let onEdit: () -> Void
    let onDelete: () -> Void
    
    @State private var showingTokens = false
    @State private var showingRealValues = false
    @State private var realUsername: String?
    @State private var realPassword: String?
    @State private var authError: String?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(credential.displayName)
                        .font(.headline)
                    
                    Text("2 tokens available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Button {
                    showingTokens.toggle()
                    if !showingTokens {
                        // Hide real values when collapsing
                        showingRealValues = false
                        realUsername = nil
                        realPassword = nil
                    }
                } label: {
                    Image(systemName: showingTokens ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless)
                
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
            }
            
            if showingTokens {
                VStack(alignment: .leading, spacing: 6) {
                    TokenCopyRow(
                        label: "Username",
                        token: credential.usernameToken.uuidString,
                        revealedValue: showingRealValues ? realUsername : nil
                    )
                    TokenCopyRow(
                        label: "Password",
                        token: credential.passwordToken.uuidString,
                        revealedValue: showingRealValues ? realPassword : nil,
                        isPassword: true
                    )
                    
                    // Reveal / Hide button
                    HStack {
                        Spacer()
                        
                        Button {
                            if showingRealValues {
                                hideRealValues()
                            } else {
                                authenticateAndReveal()
                            }
                        } label: {
                            Label(
                                showingRealValues ? "Hide Values" : "Reveal Values",
                                systemImage: showingRealValues ? "eye.slash" : "eye"
                            )
                            .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.top, 4)
                    
                    if let error = authError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
    }
    
    private func authenticateAndReveal() {
        let context = LAContext()
        var error: NSError?
        
        // Check if biometric authentication is available
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Authenticate to reveal credential values"
            ) { success, authenticationError in
                DispatchQueue.main.async {
                    if success {
                        // Fetch and display real values
                        if let values = CredentialManager.shared.getRealValues(for: credential.id) {
                            realUsername = values.username
                            realPassword = values.password
                            showingRealValues = true
                            authError = nil
                        }
                    } else {
                        authError = authenticationError?.localizedDescription ?? "Authentication failed"
                    }
                }
            }
        } else {
            authError = error?.localizedDescription ?? "Authentication not available"
        }
    }
    
    private func hideRealValues() {
        showingRealValues = false
        realUsername = nil
        realPassword = nil
        authError = nil
    }
}

// MARK: - Token Copy Row

private struct TokenCopyRow: View {
    let label: String
    let token: String
    var revealedValue: String? = nil
    var isPassword: Bool = false
    
    @State private var copied = false
    
    /// The value to display - either the revealed value or the token
    private var displayValue: String {
        revealedValue ?? token
    }
    
    /// Whether we're showing the real value
    private var isRevealed: Bool {
        revealedValue != nil
    }
    
    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            
            if isRevealed {
                // Show revealed value with green highlight
                Text(displayValue)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.green)
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                Text("(actual)")
                    .font(.caption2)
                    .foregroundStyle(.green.opacity(0.7))
            } else {
                // Show token
                Text(token)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(displayValue, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copied ? .green : .accentColor)
            }
            .buttonStyle(.borderless)
            .help(isRevealed ? "Copy actual value" : "Copy token")
        }
        .padding(6)
        .background(isRevealed ? Color.green.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Add Credential Sheet

private struct AddCredentialSheet: View {
    let credentialManager: CredentialManager
    
    @Environment(\.dismiss) private var dismiss
    
    @State private var displayName = ""
    @State private var username = ""
    @State private var password = ""
    @State private var errorMessage: String?
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Add Credential")
                .font(.headline)
            
            Form {
                TextField("Service Name", text: $displayName)
                    .textFieldStyle(.roundedBorder)
                
                TextField("Username (optional)", text: $username)
                    .textFieldStyle(.roundedBorder)
                
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                
                if let error = errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
            .formStyle(.columns)
            
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                
                Button("Add") {
                    addCredential()
                }
                .buttonStyle(.borderedProminent)
                .disabled(displayName.isEmpty || password.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 350)
    }
    
    private func addCredential() {
        do {
            try credentialManager.addCredential(
                displayName: displayName,
                username: username.isEmpty ? nil : username,
                password: password
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Edit Credential Sheet

private struct EditCredentialSheet: View {
    let credential: StoredCredential
    let credentialManager: CredentialManager
    
    @Environment(\.dismiss) private var dismiss
    
    @State private var displayName: String
    @State private var username = ""
    @State private var password = ""
    @State private var errorMessage: String?
    
    init(credential: StoredCredential, credentialManager: CredentialManager) {
        self.credential = credential
        self.credentialManager = credentialManager
        self._displayName = State(initialValue: credential.displayName)
    }
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Edit Credential")
                .font(.headline)
            
            Form {
                TextField("Service Name", text: $displayName)
                    .textFieldStyle(.roundedBorder)
                
                TextField("New Username", text: $username)
                    .textFieldStyle(.roundedBorder)
                
                SecureField("New Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                
                if let error = errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
            .formStyle(.columns)
            
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                
                Button("Save") {
                    saveCredential()
                }
                .buttonStyle(.borderedProminent)
                .disabled(displayName.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 350)
    }
    
    private func saveCredential() {
        do {
            var updated = credential
            updated.displayName = displayName
            
            try credentialManager.updateCredential(
                updated,
                username: username.isEmpty ? nil : username,
                password: password.isEmpty ? nil : password
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Import Preview

struct ImportPreviewCredential: Identifiable {
    let id = UUID()
    let displayName: String
    let username: String?
    let password: String
    var selected: Bool
}

private struct ImportPreviewSheet: View {
    @Binding var credentials: [ImportPreviewCredential]
    let credentialManager: CredentialManager
    let onDismiss: () -> Void
    
    @State private var importing = false
    @State private var importResult: CredentialImportResult?
    
    var selectedCount: Int {
        credentials.filter { $0.selected }.count
    }
    
    var body: some View {
        VStack(spacing: 16) {
            Text("Import Credentials")
                .font(.headline)
            
            Text("Select credentials to import (\(selectedCount) selected)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            List {
                ForEach($credentials) { $credential in
                    HStack {
                        Toggle("", isOn: $credential.selected)
                            .labelsHidden()
                        
                        VStack(alignment: .leading) {
                            Text(credential.displayName)
                                .font(.body)
                            
                            if let username = credential.username {
                                Text(username)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        
                        Spacer()
                    }
                }
            }
            .frame(height: 250)
            
            if let result = importResult {
                VStack(spacing: 4) {
                    Text("Imported \(result.imported) credentials")
                        .foregroundStyle(.green)
                    
                    if result.skipped > 0 {
                        Text("Skipped \(result.skipped) duplicates")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    if !result.errors.isEmpty {
                        Text("Errors: \(result.errors.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            
            HStack {
                Button("Cancel") {
                    onDismiss()
                }
                .buttonStyle(.bordered)
                
                if importResult != nil {
                    Button("Done") {
                        onDismiss()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Import") {
                        performImport()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedCount == 0 || importing)
                }
            }
        }
        .padding(24)
        .frame(width: 400)
    }
    
    private func performImport() {
        importing = true
        
        var imported = 0
        var skipped = 0
        var errors: [String] = []
        
        for credential in credentials where credential.selected {
            do {
                try credentialManager.addCredential(
                    displayName: credential.displayName,
                    username: credential.username,
                    password: credential.password
                )
                imported += 1
            } catch CredentialManagerError.duplicateCredential {
                skipped += 1
            } catch {
                errors.append(credential.displayName)
            }
        }
        
        importResult = CredentialImportResult(imported: imported, skipped: skipped, errors: errors)
        importing = false
    }
}

#Preview {
    CredentialsSettingsView()
}
