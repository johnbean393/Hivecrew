//
//  CredentialsSettingsView.swift
//  Hivecrew
//
//  Settings view for managing stored authentication credentials
//

import SwiftUI
import UniformTypeIdentifiers

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

#Preview {
    CredentialsSettingsView()
}
