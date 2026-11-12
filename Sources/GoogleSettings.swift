import SwiftUI

/// Settings › Accounts: Spotify, and for Google your OAuth client (Desktop app), the accounts Calendar and Tasks read, and which of their calendars
/// and task lists show (the Mac's own calendars while no account is signed in).
struct GooglePane: View {
    @Bindable var store: Store
    @State private var google = Google.shared
    @State private var tasks = GoogleTasks.shared
    @State private var id = ""
    @State private var secret = ""
    private var events: CalendarEvents { .shared }

    var body: some View {
        Form {
            Section("Google") {
                ForEach(google.emails, id: \.self) { email in
                    LabeledContent {
                        HStack {
                            if google.reauth.contains(email) {
                                Button("Sign in again") { google.signIn(hint: email) }.disabled(google.status == .signingIn)
                            }
                            Button("Sign out") { google.signOut(email) }
                        }
                    } label: {
                        Text(email).textSelection(.enabled)
                        if google.reauth.contains(email) { Text("Sign in again to add events from MONEY!") }
                    }
                }
                if google.ready {
                    HStack {
                        Spacer()
                        if google.status == .signingIn { Button("Cancel") { google.cancelSignIn() } }
                        Button(google.status == .signingIn ? "Signing in…" : "Add account") { google.signIn() }.disabled(google.status == .signingIn)
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
                        Button(google.status == .signingIn ? "Signing in…" : "Sign in") {
                            google.setClient(.init(id: id, secret: secret))
                            google.signIn()
                        }
                        .disabled(id.trimmingCharacters(in: .whitespaces).isEmpty || google.status == .signingIn)
                    }
                }
                if let e = google.error { Text(e).foregroundStyle(.red) }
            }
            Section("Calendars") {
                if events.authorized {
                    ForEach(events.calendars) { c in
                        toggle(c.id, in: \.eventCalendarsOff) {
                            Circle().fill(Color(nsColor: c.color)).frame(width: 9, height: 9)
                            Text(c.title)
                            if !c.source.isEmpty { Text(c.source).foregroundStyle(.secondary) }
                        }
                    }
                } else {
                    LabeledContent("Calendars on this Mac") {
                        Button(events.undecided ? "Allow access" : "Open privacy settings") { events.requestAccess() }
                    }
                }
            }
            if google.ready, !tasks.lists.isEmpty {
                Section("Task lists") {
                    ForEach(tasks.lists) { l in
                        toggle(l.id, in: \.taskListsOff) {
                            Text(l.title)
                            if google.emails.count > 1, let a = l.account { Text(a).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            SpotifySettings()
        }
        .onAppear {
            prefill()
            if events.authorized { events.reload() }
            if google.ready, tasks.age > 60 { Task { await tasks.refresh() } }
        }
    }

    /// A calendar or list shown while its id isn't in the setting's "off" list (so new ones show).
    private func toggle<Label: View>(_ id: String, in off: WritableKeyPath<Settings, [String]>, @ViewBuilder label: () -> Label) -> some View {
        Toggle(isOn: Binding(get: { !store.settings[keyPath: off].contains(id) }, set: { on in
            store.settings[keyPath: off].removeAll { $0 == id }
            if !on { store.settings[keyPath: off].append(id) }
        })) {
            HStack(spacing: 8) { label() }
        }
    }

    /// Your saved client. (Moneybag's is only read when you press Sign in: reading another app's item makes macOS
    /// ask for the password, which shouldn't happen just because this page opened.)
    private func prefill() {
        guard id.isEmpty, !google.demo else { return }
        if let c = google.client {
            id = c.id
            secret = c.secret
        }
    }
}
