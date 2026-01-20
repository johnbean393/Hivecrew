//
//  CredentialRowView.swift
//  Hivecrew
//
//  Row components for displaying credentials in settings
//

import SwiftUI
import LocalAuthentication

// MARK: - Credential Row

struct CredentialRow: View {
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
                Text(credential.displayName)
                    .font(.headline)
                
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
                    // Username is shown directly (not obfuscated) since it's not sensitive
                    if let username = CredentialManager.shared.resolveToken(credential.usernameToken.uuidString) {
                        UsernameRow(label: "Username", username: username)
                    }
                    TokenCopyRow(
                        label: "Password",
                        token: credential.passwordToken.uuidString,
                        revealedValue: showingRealValues ? realPassword : nil,
                        isPassword: true
                    )
                    
                    // Reveal / Hide button for password only
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
                                showingRealValues ? "Hide Password" : "Reveal Password",
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

// MARK: - Username Row (not obfuscated)

struct UsernameRow: View {
    let label: String
    let username: String
    
    @State private var copied = false
    
    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            
            Text(username)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(username, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copied ? .green : .accentColor)
            }
            .buttonStyle(.borderless)
            .help("Copy username")
        }
        .padding(6)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Token Copy Row

struct TokenCopyRow: View {
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
