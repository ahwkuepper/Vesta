// Copyright 2026 Andreas Kupper
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import VestaDesign

struct KasaAccountView: View {
    @Bindable var model: KasaModel
    var close: () -> Void
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Kasa account").font(.headline)
                Spacer()
                Button("Done", action: close).disabled(model.isSigningIn)
            }
            if model.signedIn {
                Label("Sign-in saved in Keychain", systemImage: "checkmark.shield")
                    .font(.messageTitle).foregroundStyle(.secondary)
            }
            Text("Use the email and password from the Kasa app to connect newer devices. Account-derived keys stay in this Mac’s Keychain; connections go directly to your devices.")
                .font(.messageBody).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 5) {
                Text("Email").font(.messageBody)
                TextField("Your TP-Link account email", text: $email).textContentType(.username)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("TP-Link account email")
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Password").font(.messageBody)
                SecureField("Password", text: $password).textContentType(.password)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("TP-Link account password")
                    .onSubmit { signIn() }
            }
            HStack {
                if model.signedIn {
                    Button("Sign out") { model.signOut() }
                        .disabled(!model.busy.isEmpty || model.isRefreshing || model.isSigningIn)
                }
                Spacer()
                if model.isSigningIn { ProgressView().controlSize(.small) }
                Button(model.signedIn ? "Update sign-in" : "Connect", action: signIn)
                    .buttonStyle(.borderedProminent)
                    .disabled(email.isEmpty || password.isEmpty || model.isSigningIn || model.isRefreshing)
            }
            Text("If a device won’t connect, check Me → Settings → Third-Party Compatibility in the Kasa app.")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .onDisappear { email = ""; password = "" }
    }

    private func signIn() {
        guard !email.isEmpty, !password.isEmpty, !model.isSigningIn, !model.isRefreshing else { return }
        let submittedEmail = email, submittedPassword = password
        password = ""
        Task {
            if await model.signIn(email: submittedEmail, password: submittedPassword) { email = ""; close() }
        }
    }
}
