import AppKit
import CryptoKit
import Network
import Observation
import Security

// Google sign-in for Calendar and Tasks, as in Moneybag: your own OAuth client (a Desktop app in Google Cloud), the
// browser with a loopback redirect and PKCE, and the tokens in the Keychain, one set per account. The client and tokens
// are never written to a file or printed.

@MainActor @Observable final class Google {
    static let shared = Google()

    enum Status: Equatable { case signedOut, signingIn, ready }

    struct Client: Codable, Equatable {
        var id: String
        var secret: String
    }

    private struct Tokens: Codable {
        var access: String
        var refresh: String
        var expires: Date
        var email: String?
        /// What Google granted (nil for sign-ins kept from before it was saved; learnt at the next refresh).
        var scope: String?
    }

    enum Failure: LocalizedError {
        case signedOut, http(Int), denied(String)
        var errorDescription: String? {
            switch self {
            case .signedOut: "Not signed in to Google"
            case .http(403): "Google refused access. Sign in again."
            case .http(let code): "Google error \(code)"
            case .denied(let why): why
            }
        }
    }

    /// Reading the calendar list needs calendar.readonly; adding events, calendar.events.
    static let scopes = "https://www.googleapis.com/auth/calendar.readonly https://www.googleapis.com/auth/calendar.events https://www.googleapis.com/auth/tasks"
    static let credentialsPage = URL(string: "https://console.cloud.google.com/apis/credentials")!
    private static let clientAccount = "google-client"
    private static let tokenAccount = "google-tokens"

    private(set) var status: Status = .signedOut
    /// The accounts signed in, in the order they were added (the first one gets new events).
    private(set) var emails: [String] = []
    /// Accounts that can't add events until they sign in again (signed in before MONEY! asked to, or Google said no).
    private(set) var reauth: Set<String> = []
    private(set) var error: String?
    /// Snapshots: no Keychain, no network.
    private(set) var demo = false

    @ObservationIgnored private var accounts: [Tokens] = []
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var refreshing: [String: Task<String, Error>] = [:]

    var ready: Bool { status == .ready }

    private init() {
        // One account was saved as a single object before; it reads as a list of one, so nobody signs in again.
        if let raw = Keychain.get(Self.tokenAccount).map({ Data($0.utf8) }) {
            accounts = (try? JSONDecoder().decode([Tokens].self, from: raw)) ?? (try? JSONDecoder().decode(Tokens.self, from: raw)).map { [$0] } ?? []
        }
        settle()
    }

    /// The observed state from the tokens.
    private func settle() {
        emails = accounts.map { $0.email ?? "" }
        reauth = reauth.union(accounts.filter { $0.scope.map { !$0.contains("calendar.events") } ?? false }.map { $0.email ?? "" })
            .intersection(emails)
        if status != .signingIn { status = accounts.isEmpty ? .signedOut : .ready }
    }

    /// Google refused to add an event for this account: it signs in again for the wider access.
    func needsSignIn(_ email: String) { reauth.insert(email) }

    // MARK: Client

    var client: Client? {
        guard let raw = Keychain.get(Self.clientAccount) else { return nil }
        return try? JSONDecoder().decode(Client.self, from: Data(raw.utf8))
    }

    func setClient(_ c: Client?) {
        let clean = c.map { Client(id: $0.id.trimmingCharacters(in: .whitespacesAndNewlines), secret: $0.secret.trimmingCharacters(in: .whitespacesAndNewlines)) }
        Keychain.set(clean.flatMap { $0.id.isEmpty ? nil : String(data: try! JSONEncoder().encode($0), encoding: .utf8) }, account: Self.clientAccount)
    }

    /// The client Moneybag signs in with, read from its Keychain item on this Mac (macOS may ask once).
    static func moneybagClient() -> Client? {
        guard Keychain.allowed else { return nil }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Ardia Connected Accounts",
                                kSecAttrAccount as String: "google-workspace", kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = json["clientId"] as? String, !id.isEmpty else { return nil }
        return Client(id: id, secret: json["clientSecret"] as? String ?? "")
    }

    /// Whether Moneybag has a client to borrow (attributes only, so macOS doesn't ask).
    static var moneybagHasClient: Bool {
        guard Keychain.allowed else { return false }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Ardia Connected Accounts",
                                kSecAttrAccount as String: "google-workspace", kSecReturnAttributes as String: true]
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    // MARK: Signing in

    /// The sign-in rows in the popup: straight to Google with a known client, otherwise Settings › Google.
    func signInOrSettings() {
        if client == nil, Self.moneybagHasClient, let c = Self.moneybagClient() { setClient(c) }
        if client != nil { return signIn() }
        Tools.openSettings()
        NotificationCenter.default.post(name: .showSettingsPane, object: Pane.google)
    }

    /// Opens Google's consent page in the browser and waits on 127.0.0.1 (a free port) for the code. A new account,
    /// or with `hint` that account again (it replaces its tokens).
    func signIn(hint: String? = nil) {
        guard !demo, status != .signingIn, let client else { return }
        let verifier = Self.random(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.random(24)
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        guard let l = try? NWListener(using: params) else { error = "Couldn’t start the sign-in"; return }
        listener?.cancel()
        listener = l
        error = nil
        status = .signingIn
        l.stateUpdateHandler = { st in
            guard case .ready = st, let port = l.port?.rawValue else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
                    c.queryItems = [.init(name: "client_id", value: client.id), .init(name: "redirect_uri", value: "http://127.0.0.1:\(port)"),
                                    .init(name: "response_type", value: "code"), .init(name: "scope", value: Self.scopes),
                                    .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
                                    .init(name: "state", value: state), .init(name: "access_type", value: "offline"),
                                    .init(name: "prompt", value: "select_account consent")]
                    if let hint { c.queryItems?.append(.init(name: "login_hint", value: hint)) }
                    if let url = c.url { NSWorkspace.shared.open(url) }
                }
            }
        }
        l.newConnectionHandler = { conn in
            conn.start(queue: .main)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                let line = data.flatMap { String(data: $0, encoding: .utf8) }?.split(separator: "\r\n").first ?? ""
                let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let items = URLComponents(string: "http://127.0.0.1" + path)?.queryItems ?? []
                let value = { (k: String) in items.first { $0.name == k }?.value }
                let answered = value("code") != nil || value("error") != nil
                let page = answered ? "<!doctype html><meta charset=utf-8><title>MONEY!</title><body style=\"font:16px -apple-system;background:#111;color:#fff;display:grid;place-items:center;height:90vh\">\(value("code") != nil ? "Signed in to MONEY!" : "Not signed in"). You can close this tab.</body>"
                    : ""
                let head = answered ? "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n" : "HTTP/1.1 404 Not Found\r\n"
                conn.send(content: Data((head + "Content-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n" + page).utf8),
                          completion: .contentProcessed { _ in conn.cancel() })
                guard answered else { return }
                MainActor.assumeIsolated {
                    let g = Google.shared
                    g.listener?.cancel()
                    g.listener = nil
                    guard value("state") == state, let code = value("code") else {
                        g.finish(value("error") == "access_denied" ? "Sign-in was cancelled" : "Google didn’t allow access")
                        return
                    }
                    Task { await g.exchange(code: code, verifier: verifier, redirect: "http://127.0.0.1:\(l.port?.rawValue ?? 0)", client: client) }
                }
            }
        }
        l.start(queue: .main)
        // Given up after five minutes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak l] in
            MainActor.assumeIsolated {
                guard let l, Google.shared.listener === l else { return }
                l.cancel()
                Google.shared.listener = nil
                Google.shared.finish("Sign-in timed out")
            }
        }
    }

    func cancelSignIn() {
        listener?.cancel()
        listener = nil
        if status == .signingIn { finish(nil) }
    }

    private func exchange(code: String, verifier: String, redirect: String, client: Client) async {
        do {
            let reply = try await Self.token(["client_id": client.id, "client_secret": client.secret, "code": code, "code_verifier": verifier,
                                              "grant_type": "authorization_code", "redirect_uri": redirect])
            guard let access = reply["access_token"] as? String, let refresh = reply["refresh_token"] as? String else {
                throw Failure.denied("Google didn’t return a refresh token")
            }
            // The primary calendar's id is the account's address.
            var req = URLRequest(url: URL(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList/primary")!, timeoutInterval: 20)
            req.setValue("Bearer " + access, forHTTPHeaderField: "Authorization")
            let primary = (try? await URLSession.shared.data(for: req)).flatMap { (try? JSONSerialization.jsonObject(with: $0.0)) as? [String: Any] }
            let t = Tokens(access: access, refresh: refresh, expires: Date().addingTimeInterval(reply["expires_in"] as? Double ?? 3000),
                           email: primary?["id"] as? String, scope: reply["scope"] as? String ?? Self.scopes)
            // The same account again replaces its tokens (signing in again for wider access).
            if let i = accounts.firstIndex(where: { $0.email == t.email }) { accounts[i] = t } else { accounts.append(t) }
            reauth.remove(t.email ?? "")
            saveTokens()
            status = .ready
            finish(nil)
            settle()
            Self.connected()
        } catch {
            finish(error.localizedDescription)
        }
    }

    private func finish(_ message: String?) {
        error = message
        if status == .signingIn { status = accounts.isEmpty ? .signedOut : .ready }
    }

    /// Signs one account out (the others stay).
    func signOut(_ email: String) {
        guard !demo, let i = accounts.firstIndex(where: { ($0.email ?? "") == email }) else { return }
        // Revoke at Google too (best effort).
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.form(["token": accounts[i].refresh])
        URLSession.shared.dataTask(with: req).resume()
        accounts.remove(at: i)
        error = nil
        saveTokens()
        settle()
        Self.connected()
    }

    /// Everything that reads Google starts over (or falls back to EventKit).
    private static func connected() {
        GoogleCalendar.shared.reset()
        GoogleTasks.shared.reset()
        CalendarEvents.shared.apply(Store.shared.settings)
        CalendarEvents.shared.reload()
        CalendarBoard.shared.load(force: true)
        if Google.shared.ready { Task { await GoogleTasks.shared.refresh() } }
    }

    /// The popup opened: catch up on anything older than a minute.
    func popupOpened() {
        guard ready, !demo else { return }
        let today = Calendar.current.startOfDay(for: Date())
        _ = GoogleCalendar.shared.events(from: today, to: Calendar.current.date(byAdding: .day, value: 2, to: today) ?? today, maxAge: 60)
        if GoogleTasks.shared.age > 60 { Task { await GoogleTasks.shared.refresh() } }
    }

    private func saveTokens() {
        Keychain.set(accounts.isEmpty ? nil : String(data: try! JSONEncoder().encode(accounts), encoding: .utf8), account: Self.tokenAccount)
    }

    // MARK: Requests

    /// A fresh access token for the account (refreshed a minute before it runs out; one refresh at a time each).
    private func accessToken(_ email: String, force: Bool = false) async throws -> String {
        guard let t = accounts.first(where: { ($0.email ?? "") == email }), let client else { throw Failure.signedOut }
        if !force, t.expires > Date().addingTimeInterval(60) { return t.access }
        if let r = refreshing[email] { return try await r.value }
        let task = Task { () throws -> String in
            defer { self.refreshing[email] = nil }
            let json: [String: Any]
            do {
                json = try await Self.token(["client_id": client.id, "client_secret": client.secret, "refresh_token": t.refresh, "grant_type": "refresh_token"])
            } catch Failure.denied(let why) where why.contains("invalid_grant") {
                // Revoked or expired: that account signed out, the client kept for signing in again.
                self.signOut(email)
                self.error = "Google signed \(email) out. Sign in again."
                throw Failure.signedOut
            }
            guard let access = json["access_token"] as? String, let i = self.accounts.firstIndex(where: { ($0.email ?? "") == email }) else { throw Failure.signedOut }
            self.accounts[i].access = access
            self.accounts[i].expires = Date().addingTimeInterval(json["expires_in"] as? Double ?? 3000)
            if let scope = json["scope"] as? String { self.accounts[i].scope = scope }
            self.saveTokens()
            self.settle()
            return access
        }
        refreshing[email] = task
        return try await task.value
    }

    /// One API call as `account` (the first one if nil); a 401 refreshes the token and tries once more. Returns the
    /// body (empty for 204).
    func call(_ url: URL, method: String = "GET", body: [String: Any]? = nil, account: String? = nil, retried: Bool = false) async throws -> Data {
        guard !demo, let email = account ?? emails.first else { throw Failure.signedOut }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = method
        req.setValue("Bearer " + (try await accessToken(email, force: retried)), forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401, !retried { return try await call(url, method: method, body: body, account: email, retried: true) }
        guard (200..<300).contains(code) else { throw Failure.http(code) }
        return data
    }

    func json(_ url: URL, account: String? = nil) async throws -> [String: Any] {
        (try JSONSerialization.jsonObject(with: try await call(url, account: account))) as? [String: Any] ?? [:]
    }

    private static func token(_ fields: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form(fields)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure.denied((json["error_description"] as? String).map { "Google: \($0)" } ?? (json["error"] as? String) ?? "Google sign-in failed")
        }
        return json
    }

    static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(fields.map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&").utf8)
    }

    static func random(_ n: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<n).map { _ in chars[Int.random(in: 0..<chars.count)] })
    }

    // MARK: Snapshots

    /// Made-up accounts (`reauth`: those that would have to sign in again to add events).
    func useDemo(signedIn: Bool, emails: [String] = ["ben@example.com"], reauth: Set<String> = []) {
        demo = true
        status = signedIn ? .ready : .signedOut
        self.emails = signedIn ? emails : []
        self.reauth = reauth
    }
}

extension Notification.Name {
    /// Settings switches to the pane in the object.
    static let showSettingsPane = Notification.Name("showSettingsPane")
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
