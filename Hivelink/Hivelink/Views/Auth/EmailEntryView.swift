//
//  EmailEntryView.swift
//  Hivelink
//

import HivecrewCore
import SwiftUI

struct EmailEntryView: View {
    @EnvironmentObject private var authManager: RemoteAccessAuthManager
    var onAwaitingOTP: () -> Void

    @State private var email = ""
    @FocusState private var isEmailFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sign in with your email")
                .font(.title3)
                .foregroundStyle(.secondary)

            TextField("Email", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(12)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                .focused($isEmailFocused)

            if authManager.status == .error, let message = authManager.errorMessage {
                errorBanner(message)
            }

            Button {
                Task {
                    await authManager.requestOTP(email: email.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            } label: {
                if authManager.status == .connecting {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Continue")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canContinue)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            isEmailFocused = true
        }
        .onChange(of: authManager.status) { oldValue, newValue in
            if oldValue == .connecting, newValue == .awaitingOTP {
                onAwaitingOTP()
            }
        }
    }

    private var canContinue: Bool {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.contains("@") else { return false }
        return authManager.status != .connecting
    }

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(.subheadline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.red.opacity(0.9), in: RoundedRectangle(cornerRadius: 10))
    }
}

#Preview {
    EmailEntryView(onAwaitingOTP: {})
        .environmentObject(RemoteAccessAuthManager())
        .padding()
}
