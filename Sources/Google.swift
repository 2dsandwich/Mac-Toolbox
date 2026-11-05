import AppKit
import CryptoKit
import Network
import Observation
import Security

// Google sign-in for Calendar and Tasks, as in Moneybag: your own OAuth client (a Desktop app in Google Cloud), the
// browser with a loopback redirect and PKCE, and the tokens in the Keychain. The client and tokens are never written
// to a file or printed.

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

    static let scopes = "https://www.googleapis.com/auth/calendar.readonly https://www.googleapis.com/auth/tasks"
    static let credentialsPage = URL(string: "https://console.cloud.google.com/apis/credentials")!
    private static let clientAccount = "google-client"
    private static let tokenAccount = "google-tokens"

    private(set) var status: Status = .signedOut
    private(set) var email: String?
    private(set) var error: String?
    /// Snapshots: no Keychain, no network.
    private(set) var demo = false

    @ObservationIgnored private var tokens: Tokens?
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var refreshing: Task<String, Error>?

    var ready: Bool { status == .ready }

    private init() {
        if let raw = Keychain.get(Self.tokenAccount), let t = try? JSONDecoder().decode(Tokens.self, from: Data(raw.utf8)) {
            tokens = t
            email = t.email
            status = .ready
        }
    }

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

    /// Opens Google's consent page in the browser and waits on 127.0.0.1 (a free port) for the code.
    func signIn() {
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
                                    .init(name: "state", value: state), .init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent")]
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
            tokens = Tokens(access: access, refresh: refresh, expires: Date().addingTimeInterval(reply["expires_in"] as? Double ?? 3000))
            // The primary calendar's id is the account's address.
            let primary = try? await json(URL(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList/primary")!)
            tokens?.email = primary?["id"] as? String
            saveTokens()
            email = tokens?.email
            finish(nil)
            status = .ready
            Self.connected()
        } catch {
            finish(error.localizedDescription)
        }
    }

    private func finish(_ message: String?) {
        error = message
        if status == .signingIn { status = tokens == nil ? .signedOut : .ready }
    }

    func signOut() {
        guard !demo else { return }
        if let t = tokens {
            // Revoke at Google too (best effort).
            var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Self.form(["token": t.refresh])
            URLSession.shared.dataTask(with: req).resume()
        }
        tokens = nil
        email = nil
        error = nil
        Keychain.set(nil, account: Self.tokenAccount)
        status = .signedOut
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
        Keychain.set(tokens.flatMap { String(data: try! JSONEncoder().encode($0), encoding: .utf8) }, account: Self.tokenAccount)
    }

    // MARK: Requests

    /// A fresh access token (refreshed a minute before it runs out; one refresh at a time).
    private func accessToken(force: Bool = false) async throws -> String {
        guard let t = tokens, let client else { throw Failure.signedOut }
        if !force, t.expires > Date().addingTimeInterval(60) { return t.access }
        if let refreshing { return try await refreshing.value }
        let task = Task { () throws -> String in
            defer { self.refreshing = nil }
            let json: [String: Any]
            do {
                json = try await Self.token(["client_id": client.id, "client_secret": client.secret, "refresh_token": t.refresh, "grant_type": "refresh_token"])
            } catch Failure.denied(let why) where why.contains("invalid_grant") {
                // Revoked or expired: signed out, the client kept for signing in again.
                self.signOut()
                self.error = "Google signed you out. Sign in again."
                throw Failure.signedOut
            }
            guard let access = json["access_token"] as? String else { throw Failure.signedOut }
            self.tokens?.access = access
            self.tokens?.expires = Date().addingTimeInterval(json["expires_in"] as? Double ?? 3000)
            self.saveTokens()
            return access
        }
        refreshing = task
        return try await task.value
    }

    /// One API call; a 401 refreshes the token and tries once more. Returns the body (empty for 204).
    func call(_ url: URL, method: String = "GET", body: [String: Any]? = nil, retried: Bool = false) async throws -> Data {
        guard !demo else { throw Failure.signedOut }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = method
        req.setValue("Bearer " + (try await accessToken(force: retried)), forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401, !retried { return try await call(url, method: method, body: body, retried: true) }
        guard (200..<300).contains(code) else { throw Failure.http(code) }
        return data
    }

    func json(_ url: URL) async throws -> [String: Any] {
        (try JSONSerialization.jsonObject(with: try await call(url))) as? [String: Any] ?? [:]
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

    private static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(fields.map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&").utf8)
    }

    private static func random(_ n: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<n).map { _ in chars[Int.random(in: 0..<chars.count)] })
    }

    // MARK: Snapshots

    func useDemo(signedIn: Bool, email: String? = nil) {
        demo = true
        status = signedIn ? .ready : .signedOut
        self.email = email
    }
}

extension Notification.Name {
    /// Settings switches to the pane in the object.
    static let showSettingsPane = Notification.Name("showSettingsPane")
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
