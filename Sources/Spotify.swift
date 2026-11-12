import AppKit
import CryptoKit
import Network
import Observation
import SwiftUI

// Spotify sign-in, only so the notch's heart can like songs: your own app at developer.spotify.com (a Client ID; PKCE,
// no secret), the browser with a loopback redirect, and the tokens in the Keychain. Never written to a file or printed.

@MainActor @Observable final class Spotify {
    static let shared = Spotify()

    static let port: UInt16 = 47476
    /// What the app at developer.spotify.com must list as its Redirect URI, exactly.
    static let redirect = "http://127.0.0.1:47476/callback"
    static let dashboard = URL(string: "https://developer.spotify.com/dashboard")!
    private static let scopes = "user-library-read user-library-modify"
    private static let clientAccount = "spotify-client", tokenAccount = "spotify-tokens"

    private struct Tokens: Codable {
        var access: String
        var refresh: String
        var expires: Date
    }

    private(set) var ready = false
    private(set) var signingIn = false
    private(set) var error: String?

    @ObservationIgnored private var tokens: Tokens?
    @ObservationIgnored private var listener: NWListener?

    private init() {
        if let raw = Keychain.get(Self.tokenAccount), let t = try? JSONDecoder().decode(Tokens.self, from: Data(raw.utf8)) {
            tokens = t
            ready = true
        }
    }

    var clientID: String { Keychain.get(Self.clientAccount) ?? "" }

    /// Settings › Notch, where the Client ID goes.
    func showSettings() {
        Tools.openSettings()
        NotificationCenter.default.post(name: .showSettingsPane, object: Pane.google)
    }

    // MARK: Signing in

    /// Opens Spotify's consent page in the browser and waits on 127.0.0.1:47476 for the code.
    func signIn(clientID raw: String) {
        let client = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !client.isEmpty, !signingIn else { return }
        Keychain.set(client, account: Self.clientAccount)
        let verifier = Google.random(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Google.random(24)
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params) else { error = "Couldn’t start the sign-in"; return }
        listener?.cancel()
        listener = l
        error = nil
        signingIn = true
        l.stateUpdateHandler = { st in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch st {
                    case .ready:
                        var c = URLComponents(string: "https://accounts.spotify.com/authorize")!
                        c.queryItems = [.init(name: "client_id", value: client), .init(name: "response_type", value: "code"),
                                        .init(name: "redirect_uri", value: Self.redirect), .init(name: "scope", value: Self.scopes),
                                        .init(name: "code_challenge_method", value: "S256"), .init(name: "code_challenge", value: challenge),
                                        .init(name: "state", value: state)]
                        if let url = c.url { NSWorkspace.shared.open(url) }
                    case .failed:
                        Spotify.shared.stop("Port \(Self.port) is in use. Quit what’s using it and try again.")
                    default: break
                    }
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
                let answered = path.hasPrefix("/callback") && (value("code") != nil || value("error") != nil)
                let page = answered ? "<!doctype html><meta charset=utf-8><title>MONEY!</title><body style=\"font:16px -apple-system;background:#111;color:#fff;display:grid;place-items:center;height:90vh\">\(value("code") != nil ? "Signed in to MONEY!" : "Not signed in"). You can close this tab.</body>" : ""
                let head = answered ? "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n" : "HTTP/1.1 404 Not Found\r\n"
                conn.send(content: Data((head + "Content-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n" + page).utf8),
                          completion: .contentProcessed { _ in conn.cancel() })
                guard answered else { return }
                MainActor.assumeIsolated {
                    let s = Spotify.shared
                    guard value("state") == state, let code = value("code") else {
                        return s.stop(value("error") == "access_denied" ? "Sign-in was cancelled" : "Spotify didn’t allow access")
                    }
                    s.listener?.cancel()
                    s.listener = nil
                    Task { await s.exchange(code: code, verifier: verifier, client: client) }
                }
            }
        }
        l.start(queue: .main)
        // Given up after five minutes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak l] in
            MainActor.assumeIsolated {
                guard let l, Spotify.shared.listener === l else { return }
                Spotify.shared.stop("Sign-in timed out")
            }
        }
    }

    func cancelSignIn() { stop(nil) }

    private func stop(_ message: String?) {
        listener?.cancel()
        listener = nil
        signingIn = false
        error = message
    }

    private func exchange(code: String, verifier: String, client: String) async {
        do {
            let reply = try await Self.token(["grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirect,
                                              "client_id": client, "code_verifier": verifier])
            guard let access = reply["access_token"] as? String, let refresh = reply["refresh_token"] as? String else {
                throw Google.Failure.denied("Spotify didn’t return a refresh token")
            }
            tokens = Tokens(access: access, refresh: refresh, expires: Date().addingTimeInterval(reply["expires_in"] as? Double ?? 3000))
            saveTokens()
            ready = true
            stop(nil)
            NowPlaying.shared.checkSpotifyLike()
        } catch {
            stop(error.localizedDescription)
        }
    }

    func signOut() {
        tokens = nil
        Keychain.set(nil, account: Self.tokenAccount)
        ready = false
        error = nil
        NowPlaying.shared.liked = nil
    }

    private func saveTokens() {
        Keychain.set(tokens.flatMap { String(data: try! JSONEncoder().encode($0), encoding: .utf8) }, account: Self.tokenAccount)
    }

    private func accessToken(force: Bool) async throws -> String {
        guard let t = tokens else { throw Google.Failure.signedOut }
        if !force, t.expires > Date().addingTimeInterval(60) { return t.access }
        let json: [String: Any]
        do {
            json = try await Self.token(["grant_type": "refresh_token", "refresh_token": t.refresh, "client_id": clientID])
        } catch Google.Failure.denied(let why) where why.contains("invalid_grant") {
            // Revoked: signed out, the Client ID kept for signing in again.
            signOut()
            error = "Spotify signed you out. Sign in again."
            throw Google.Failure.signedOut
        }
        guard let access = json["access_token"] as? String else { throw Google.Failure.signedOut }
        tokens?.access = access
        tokens?.expires = Date().addingTimeInterval(json["expires_in"] as? Double ?? 3000)
        if let r = json["refresh_token"] as? String { tokens?.refresh = r } // Spotify may hand out a new one
        saveTokens()
        return access
    }

    private static func token(_ fields: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Google.form(fields)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let why = [json["error"] as? String, json["error_description"] as? String].compactMap { $0 }.joined(separator: ": ")
            throw Google.Failure.denied(why.isEmpty ? "Spotify sign-in failed" : "Spotify: \(why)")
        }
        return json
    }

    // MARK: Liked Songs (the library endpoints from February 2026)

    func isSaved(_ uri: String) async -> Bool? {
        guard let d = try? await call("GET", "/me/library/contains", uri) else { return nil }
        return ((try? JSONSerialization.jsonObject(with: d)) as? [Bool])?.first
    }

    /// Adds to or removes from Liked Songs; false if Spotify refused.
    func save(_ uri: String, _ on: Bool) async -> Bool {
        (try? await call(on ? "PUT" : "DELETE", "/me/library", uri)) != nil
    }

    /// One call; a 401 refreshes the token and tries once more.
    private func call(_ method: String, _ path: String, _ uri: String, retried: Bool = false) async throws -> Data {
        var c = URLComponents(string: "https://api.spotify.com/v1" + path)!
        c.queryItems = [.init(name: "uris", value: uri)]
        var req = URLRequest(url: c.url!, timeoutInterval: 15)
        req.httpMethod = method
        req.setValue("Bearer " + (try await accessToken(force: retried)), forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401, !retried { return try await call(method, path, uri, retried: true) }
        guard (200..<300).contains(code) else { throw Google.Failure.http(code) }
        return data
    }
}

/// Settings › Accounts: the Client ID and signing in, for the heart on Spotify songs in the notch.
struct SpotifySettings: View {
    @State private var spotify = Spotify.shared
    @State private var id = ""

    var body: some View {
        Section {
            if spotify.ready {
                HStack {
                    Text("Signed in")
                    Spacer()
                    Button("Sign out") { spotify.signOut() }
                }
            } else {
                TextField("Client ID", text: $id)
                HStack {
                    Link("Spotify dashboard", destination: Spotify.dashboard)
                    Spacer()
                    if spotify.signingIn { Button("Cancel") { spotify.cancelSignIn() } }
                    Button(spotify.signingIn ? "Signing in…" : "Sign in") { spotify.signIn(clientID: id) }
                        .disabled(id.trimmingCharacters(in: .whitespaces).isEmpty || spotify.signingIn)
                }
            }
            if let e = spotify.error { Text(e).foregroundStyle(.red) }
        } header: {
            Text("Spotify")
        } footer: {
            if !spotify.ready {
                Text("To like songs from the notch, create an app in the Spotify dashboard with the Web API and the Redirect URI \(Spotify.redirect), then paste its Client ID here.")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .onAppear { if id.isEmpty { id = spotify.clientID } }
    }
}
