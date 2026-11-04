import Foundation
import Security

/// The Anthropic API key lives in the login Keychain, never in settings files.
enum Keychain {
    private static let service = "dev.masashik.flick"

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String?, account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Minimal Messages API client (raw HTTPS; Swift has no official Anthropic SDK).
enum Claude {
    static let keyAccount = "anthropic-api-key"
    private static var cachedKey: String??

    static var apiKey: String? {
        if let cachedKey { return cachedKey }
        let k = Keychain.get(keyAccount)
        cachedKey = .some(k)
        return k
    }

    static func setAPIKey(_ key: String?) {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.set(trimmed, account: keyAccount)
        cachedKey = .some(trimmed?.isEmpty == false ? trimmed : nil)
    }

    static var hasKey: Bool { !(apiKey ?? "").isEmpty }

    enum Failure: LocalizedError {
        case noKey, http(Int, String), refused, empty
        var errorDescription: String? {
            switch self {
            case .noKey: "No Claude API key (Settings › Claude)"
            case .http(let code, let msg): "Claude error \(code): \(msg)"
            case .refused: "Claude declined this request"
            case .empty: "Claude returned no text"
            }
        }
    }

    /// One request, text in → text out. `effort` is low for dictation, higher for summaries.
    static func complete(system: String, user: String, model: String, effort: String,
                         maxTokens: Int = 4096, timeout: TimeInterval = 20, imageJPEG: Data? = nil, fallback: Bool = true) async throws -> String {
        guard let key = apiKey, !key.isEmpty else { throw Failure.noKey }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": imageJPEG.map { img -> Any in
                [["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": img.base64EncodedString()]],
                 ["type": "text", "text": user]]
            } ?? user]],
            "output_config": ["effort": effort],
        ]
        if fallback, !model.contains("haiku") {
            // If a safety classifier declines, the server retries on a fallback model instead of failing.
            req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            body["fallbacks"] = "default"
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let msg = ((json["error"] as? [String: Any])?["message"] as? String) ?? String(data: data, encoding: .utf8) ?? ""
            throw Failure.http(status, msg)
        }
        if json["stop_reason"] as? String == "refusal" { throw Failure.refused }
        let blocks = json["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw Failure.empty }
        return text
    }

    /// One streamed turn of a conversation, with server tools (web search). `onUpdate` gets the content blocks so far
    /// after every event; the result is the assistant's blocks exactly as sent (search results carry encrypted
    /// content that the next turn must send back unchanged) and the stop reason.
    @MainActor static func stream(system: String, messages: [[String: Any]], model: String, effort: String, maxTokens: Int,
                                  tools: [[String: Any]], timeout: TimeInterval, fallback: Bool,
                                  onUpdate: @escaping @MainActor ([[String: Any]]) -> Void) async throws -> (blocks: [[String: Any]], stop: String) {
        guard let key = apiKey, !key.isEmpty else { throw Failure.noKey }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        var body: [String: Any] = ["model": model, "max_tokens": maxTokens, "system": system, "messages": messages,
                                   "output_config": ["effort": effort], "stream": true]
        if !tools.isEmpty { body["tools"] = tools }
        if fallback, !model.contains("haiku") {
            req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            body["fallbacks"] = "default"
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var raw = ""
            for try await line in bytes.lines { raw += line }
            let json = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
            throw Failure.http(status, ((json["error"] as? [String: Any])?["message"] as? String) ?? String(raw.prefix(300)))
        }
        var blocks: [[String: Any]] = []
        var inputs: [Int: String] = [:] // tool inputs arrive as pieces of JSON
        var stop = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data:"),
                  let e = (try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8))) as? [String: Any] else { continue }
            let i = e["index"] as? Int ?? -1
            switch e["type"] as? String {
            case "content_block_start":
                guard i >= 0, let b = e["content_block"] as? [String: Any] else { continue }
                while blocks.count <= i { blocks.append([:]) }
                blocks[i] = b
            case "content_block_delta":
                guard blocks.indices.contains(i), let d = e["delta"] as? [String: Any] else { continue }
                switch d["type"] as? String {
                case "text_delta": blocks[i]["text"] = (blocks[i]["text"] as? String ?? "") + (d["text"] as? String ?? "")
                case "thinking_delta": blocks[i]["thinking"] = (blocks[i]["thinking"] as? String ?? "") + (d["thinking"] as? String ?? "")
                case "signature_delta": blocks[i]["signature"] = d["signature"]
                case "citations_delta":
                    if let c = d["citation"] { blocks[i]["citations"] = ((blocks[i]["citations"] as? [Any]) ?? []) + [c] }
                case "input_json_delta": inputs[i, default: ""] += d["partial_json"] as? String ?? ""
                default: break
                }
            case "content_block_stop":
                if let json = inputs.removeValue(forKey: i), !json.isEmpty, blocks.indices.contains(i),
                   let input = try? JSONSerialization.jsonObject(with: Data(json.utf8)) {
                    blocks[i]["input"] = input
                }
            case "message_delta":
                if let s = (e["delta"] as? [String: Any])?["stop_reason"] as? String { stop = s }
            case "error":
                let msg = (e["error"] as? [String: Any])?["message"] as? String ?? "Stream failed"
                throw AIError.unavailable("Claude: \(msg)")
            default:
                continue
            }
            onUpdate(blocks)
        }
        if stop == "refusal" { throw Failure.refused }
        return (blocks.filter { !$0.isEmpty }, stop)
    }
}
