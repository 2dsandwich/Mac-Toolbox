import SwiftUI

/// Settings › Google: your OAuth client (Desktop app) and the account Calendar and Tasks read.
struct GooglePane: View {
    @State private var google = Google.shared
    @State private var id = ""
    @State private var secret = ""

    var body: some View {
        Form {
            Section("Account") {
                if google.ready {
                    LabeledContent("Signed in as") { Text(google.email ?? "Google").textSelection(.enabled) }
                    HStack {
                        Spacer()
                        Button("Sign Out") { google.signOut() }
                    }
                } else {
                    TextField("Client ID", text: $id)
                    SecureField("Client secret", text: $secret)
                    HStack {
                        Link("Google Cloud credentials", destination: Google.credentialsPage)
                        Spacer()
                        if google.status == .signingIn {
                            Button("Cancel") { google.cancelSignIn() }
                        }
                        Button(google.status == .signingIn ? "Signing In…" : "Sign In") {
                            google.setClient(.init(id: id, secret: secret))
                            google.signIn()
                        }
                        .disabled(id.trimmingCharacters(in: .whitespaces).isEmpty || google.status == .signingIn)
                    }
                }
                if let e = google.error { Text(e).foregroundStyle(.red) }
            }
        }
        .onAppear(perform: prefill)
    }

    /// Your saved client. (Moneybag's is only read when you press Sign In: reading another app's item makes macOS
    /// ask for the password, which shouldn't happen just because this page opened.)
    private func prefill() {
        guard id.isEmpty, !google.demo else { return }
        if let c = google.client {
            id = c.id
            secret = c.secret
        }
    }
}
