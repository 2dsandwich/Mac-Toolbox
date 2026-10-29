import AppKit
import FoundationModels

/// Where a job's text goes: Apple's on-device model (the default; nothing to download, nothing leaves the Mac),
/// Claude, any OpenAI-compatible service, or open models running locally in Ollama / LM Studio.
enum AIProvider: String, Codable, CaseIterable, Identifiable {
    case apple, ollama, lmstudio, anthropic, openai, gemini, openrouter, groq, mistral, xai, deepseek, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: "On this Mac (Apple)"
        case .ollama: "Ollama (open models)"
        case .lmstudio: "LM Studio (open models)"
        case .anthropic: "Anthropic Claude"
        case .openai: "OpenAI"
        case .gemini: "Google Gemini"
        case .openrouter: "OpenRouter"
        case .groq: "Groq"
        case .mistral: "Mistral"
        case .xai: "xAI Grok"
        case .deepseek: "DeepSeek"
        case .custom: "Custom (OpenAI-compatible)"
        }
    }

    var short: String {
        switch self {
        case .apple: "On-device"
        case .ollama: "Ollama"
        case .lmstudio: "LM Studio"
        case .anthropic: "Claude"
        case .openai: "OpenAI"
        case .gemini: "Gemini"
        case .openrouter: "OpenRouter"
        case .groq: "Groq"
        case .mistral: "Mistral"
        case .xai: "Grok"
        case .deepseek: "DeepSeek"
        case .custom: "Custom"
        }
    }

    var symbol: String {
        switch self {
        case .apple: "apple.logo"
        case .ollama, .lmstudio: "desktopcomputer"
        case .custom: "server.rack"
        default: "cloud.fill"
        }
    }

    /// Runs on this Mac: nothing is sent anywhere.
    var isLocal: Bool { self == .apple || self == .ollama || self == .lmstudio }
    var needsKey: Bool { !isLocal && self != .custom }

    var defaultBaseURL: String {
        switch self {
        case .apple: ""
        case .ollama: "http://localhost:11434"
        case .lmstudio: "http://localhost:1234/v1"
        case .anthropic: "https://api.anthropic.com/v1"
        case .openai: "https://api.openai.com/v1"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta/openai"
        case .openrouter: "https://openrouter.ai/api/v1"
        case .groq: "https://api.groq.com/openai/v1"
        case .mistral: "https://api.mistral.ai/v1"
        case .xai: "https://api.x.ai/v1"
        case .deepseek: "https://api.deepseek.com/v1"
        case .custom: "http://localhost:8080/v1"
        }
    }

    var keyAccount: String { self == .anthropic ? Claude.keyAccount : "\(rawValue)-api-key" }
    var keyURL: String? {
        switch self {
        case .anthropic: "https://console.anthropic.com/settings/keys"
        case .openai: "https://platform.openai.com/api-keys"
        case .gemini: "https://aistudio.google.com/apikey"
        case .openrouter: "https://openrouter.ai/keys"
        case .groq: "https://console.groq.com/keys"
        case .mistral: "https://console.mistral.ai/api-keys"
        case .xai: "https://console.x.ai"
        case .deepseek: "https://platform.deepseek.com/api_keys"
        default: nil
        }
    }

    /// A starting point; "Load models" fetches the service's real list.
    var suggestedModels: [String] {
        switch self {
        case .apple: ["On-device"]
        case .ollama: OpenModel.all.map(\.name)
        case .anthropic: ClaudeModel.allCases.map(\.rawValue)
        case .openai: ["gpt-5", "gpt-5-mini", "gpt-5-nano"]
        case .gemini: ["gemini-2.5-flash", "gemini-2.5-pro", "gemini-2.5-flash-lite"]
        case .openrouter: ["anthropic/claude-opus-5-5", "openai/gpt-5", "google/gemini-2.5-flash", "qwen/qwen3-235b-a22b"]
        case .groq: ["llama-3.3-70b-versatile", "qwen/qwen3-32b", "openai/gpt-oss-120b"]
        case .mistral: ["mistral-small-latest", "mistral-medium-latest", "mistral-large-latest"]
        case .xai: ["grok-4", "grok-4-fast"]
        case .deepseek: ["deepseek-chat", "deepseek-reasoner"]
        case .lmstudio, .custom: []
        }
    }

    /// Can look at a screenshot. Text-only models get the screen's text (read on this Mac) instead.
    func seesImages(_ model: String) -> Bool {
        switch self {
        case .anthropic, .openai, .gemini, .openrouter, .xai: return true
        case .ollama, .lmstudio, .custom:
            let m = model.lowercased()
            return ["gemma3", "vl", "llava", "vision", "minicpm-v", "mistral-small3", "llama4"].contains { m.contains($0) }
        default: return false
        }
    }
}

/// The jobs that use a language model. Each has its own model and tuned defaults.
enum AITask: String, Codable, CaseIterable, Identifiable {
    case dictation, voiceEdit, meetingChat, meetingNotes, translate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictation: "Dictation cleanup"
        case .voiceEdit: "Edit by voice"
        case .meetingChat: "Meeting chat"
        case .meetingNotes: "Meeting notes"
        case .translate: "Translate"
        }
    }

    var detail: String {
        switch self {
        case .dictation: "Fixes punctuation and filler words as you dictate. Needs to be fast."
        case .voiceEdit: "Rewrites selected text from a spoken instruction."
        case .meetingChat: "Answers questions about a meeting, during or after it."
        case .meetingNotes: "Writes the notes when a meeting ends. Long transcripts."
        case .translate: "“tr …” in the search bar."
        }
    }

    var symbol: String {
        switch self {
        case .dictation: "mic.fill"
        case .voiceEdit: "wand.and.stars"
        case .meetingChat: "text.bubble.fill"
        case .meetingNotes: "doc.text.fill"
        case .translate: "character.bubble.fill"
        }
    }

    // Tuned per job: cleanup and translation stay literal, chat and notes get a little room.
    var temperature: Double {
        switch self {
        case .dictation: 0
        case .voiceEdit: 0.2
        case .translate: 0.2
        case .meetingNotes: 0.3
        case .meetingChat: 0.4
        }
    }

    var maxTokens: Int {
        switch self {
        case .dictation: 2048
        case .voiceEdit: 4096
        case .meetingChat: 800
        case .meetingNotes: 4096
        case .translate: 2048
        }
    }

    /// Claude's effort for the job.
    var effort: String {
        switch self {
        case .dictation, .meetingChat, .translate: "low"
        case .voiceEdit, .meetingNotes: "medium"
        }
    }

    var timeout: TimeInterval {
        switch self {
        case .dictation: 12
        case .translate: 30
        case .voiceEdit, .meetingChat: 60
        case .meetingNotes: 300
        }
    }

    /// Extra rules for small local models, which follow long prompts less faithfully.
    var smallModelRules: String {
        switch self {
        case .dictation: "" // its own short prompt with examples (Prompts.cleanupCompact)
        case .voiceEdit: "\n\nReply with only the new text: no <<< >>> markers, no quotes, no explanation."
        case .translate: "\n\nReply with the translation only."
        case .meetingChat: "\n\nBe brief. If the transcript doesn't say, say you don't know."
        case .meetingNotes: "\n\nOnly include what the transcript says."
        }
    }

    /// The open model picked for this job (Ollama), sized for a 16 GB Mac.
    var recommendedOpenModel: OpenModel {
        switch self {
        case .dictation: OpenModel.all[0]
        case .voiceEdit, .meetingNotes: OpenModel.all[1]
        case .meetingChat, .translate: OpenModel.all[2]
        }
    }
}

/// Open models worth having, with why.
struct OpenModel: Identifiable {
    let name: String
    let size: String
    let why: String
    var id: String { name }

    static let all = [
        OpenModel(name: "qwen3:4b", size: "2.5 GB", why: "Fast and good at Japanese and English: dictation cleanup"),
        OpenModel(name: "qwen3:8b", size: "5.2 GB", why: "Careful rewriting and long notes"),
        OpenModel(name: "gemma3:4b", size: "3.3 GB", why: "Strong translation, and it can see screenshots: chat and translate"),
        OpenModel(name: "gemma3:12b", size: "8.1 GB", why: "Better answers and screenshots, needs more memory"),
    ]
}

/// One job's choice of service and model, plus optional overrides.
struct TaskModel: Codable, Equatable {
    var provider = AIProvider.apple
    var model = "On-device"
    var temperature: Double?
    var maxTokens: Int?
}

/// Per-service options. Only the ones a service uses are shown in Settings.
struct ProviderSettings: Codable, Equatable {
    var baseURL = ""
    // Claude
    var effort = "auto"
    var fallback = true
    // OpenAI-compatible
    var reasoning = "default"
    // Ollama
    var contextLength = 8192
    var keepAlive = 10
    var thinking = false
    // Apple
    var greedy = true
}

enum AIError: LocalizedError {
    case noKey(AIProvider), unavailable(String), http(Int, String), empty, badURL

    var errorDescription: String? {
        switch self {
        case .noKey(let p): "No \(p.short) API key (Settings › AI)"
        case .unavailable(let why): why
        case .http(let code, let msg): "Error \(code): \(msg)"
        case .empty: "The model returned nothing"
        case .badURL: "That server address isn’t valid (Settings › AI)"
        }
    }
}

@MainActor enum AI {
    static func choice(_ task: AITask, _ s: Settings) -> TaskModel {
        if let c = s.aiTasks[task.rawValue] { return c }
        // Polishing speech needs a model that keeps every word and applies "no, actually…" corrections; Apple's
        // on-device one drops sentences and keeps fillers. With a Claude key, Haiku does it (on-device is the fallback).
        if task == .dictation || task == .voiceEdit, key(.anthropic) != nil { return TaskModel(provider: .anthropic, model: "claude-haiku-5-5") }
        return TaskModel()
    }
    static func options(_ p: AIProvider, _ s: Settings) -> ProviderSettings { s.aiProviders[p.rawValue] ?? ProviderSettings() }
    static func baseURL(_ p: AIProvider, _ s: Settings) -> String {
        let b = options(p, s).baseURL.trimmingCharacters(in: .whitespaces)
        return (b.isEmpty ? p.defaultBaseURL : b).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func key(_ p: AIProvider) -> String? {
        if p == .anthropic { return Claude.apiKey }
        return Keychain.get(p.keyAccount).flatMap { $0.isEmpty ? nil : $0 }
    }

    static func setKey(_ value: String?, for p: AIProvider) {
        if p == .anthropic { return Claude.setAPIKey(value) }
        Keychain.set(value?.trimmingCharacters(in: .whitespacesAndNewlines), account: p.keyAccount)
    }

    static var appleStatus: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in System Settings to use the on-device model"
        case .unavailable(.modelNotReady): return "Apple’s on-device model is still downloading"
        case .unavailable(.deviceNotEligible): return "This Mac can’t run Apple’s on-device model"
        default: return "Apple’s on-device model isn’t available"
        }
    }

    /// Why a job can't run right now (nil = ready).
    static func problem(_ task: AITask, _ s: Settings) -> String? {
        let c = choice(task, s)
        if c.provider == .apple { return appleStatus }
        if c.provider.needsKey, key(c.provider) == nil { return AIError.noKey(c.provider).errorDescription }
        if c.model.trimmingCharacters(in: .whitespaces).isEmpty { return "Pick a model for \(task.title) (Settings › AI)" }
        return nil
    }

    static func label(_ task: AITask, _ s: Settings) -> String {
        let c = choice(task, s)
        return c.provider == .apple ? "on-device model" : "\(c.provider.short) \(c.model)"
    }

    /// How much text fits in one request (characters, conservative for Japanese).
    static func budget(_ task: AITask, _ s: Settings) -> Int {
        let c = choice(task, s)
        switch c.provider {
        case .apple: return 3000
        case .ollama: return max(2000, options(.ollama, s).contextLength - 1500)
        case .lmstudio, .custom: return 6000
        default: return 150_000
        }
    }

    // MARK: Requests

    static func complete(_ task: AITask, system: String, user: String, imageJPEG: Data? = nil) async throws -> String {
        let s = Store.shared.settings
        let c = choice(task, s)
        let temperature = c.temperature ?? task.temperature
        let maxTokens = c.maxTokens ?? task.maxTokens
        var user = user
        var image = imageJPEG
        let system = c.provider.isLocal ? system + task.smallModelRules : system
        if let img = image, !c.provider.seesImages(c.model) {
            // Text-only model: read the screenshot here and send its words instead.
            if let text = await screenText(img), !text.isEmpty { user += "\n\nText on the user's screen:\n" + String(text.prefix(4000)) }
            image = nil
        }
        let raw = try await withTimeLimit(task.timeout + 5) {
            try await route(c, task: task, s: s, system: system, user: user, image: image, temperature: temperature, maxTokens: maxTokens)
        }
        var out = stripThinking(raw)
        if task == .dictation || task == .translate,
           !out.unicodeScalars.contains(where: { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }) {
            // English text with Japanese punctuation (small models over-apply the 。 rule).
            out = out.replacingOccurrences(of: "。", with: ".").replacingOccurrences(of: "、", with: ",")
        }
        if task == .voiceEdit {
            // Some models echo the markers around the selection.
            out = out.replacingOccurrences(of: #"^<<<\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s*>>>$"#, with: "", options: .regularExpression)
        }
        guard !out.isEmpty else { throw AIError.empty }
        return out
    }

    /// Starts loading the on-device model in the background (it takes a moment the first time).
    static func prewarm(_ task: AITask) {
        guard choice(task, Store.shared.settings).provider == .apple, appleStatus == nil else { return }
        LanguageModelSession(model: .default).prewarm()
    }

    private static func route(_ c: TaskModel, task: AITask, s: Settings, system: String, user: String, image: Data?, temperature: Double, maxTokens: Int) async throws -> String {
        let raw: String
        switch c.provider {
        case .apple:
            raw = try await apple(system: system, user: user, temperature: temperature, maxTokens: maxTokens, greedy: options(.apple, s).greedy && temperature == 0)
        case .anthropic:
            let o = options(.anthropic, s)
            raw = try await Claude.complete(system: system, user: user, model: c.model, effort: o.effort == "auto" ? task.effort : o.effort,
                                            maxTokens: maxTokens, timeout: task.timeout, imageJPEG: image, fallback: o.fallback)
        case .ollama:
            raw = try await ollama(base: baseURL(.ollama, s), model: c.model, system: system, user: user, image: image, temperature: temperature,
                                   maxTokens: maxTokens, o: options(.ollama, s), timeout: task.timeout)
        default:
            raw = try await openAI(c.provider, base: baseURL(c.provider, s), model: c.model, system: system, user: user, image: image,
                                   temperature: temperature, maxTokens: maxTokens, reasoning: options(c.provider, s).reasoning, timeout: task.timeout)
        }
        return raw
    }

    /// Gives up on a request that takes too long (a stuck model shouldn't leave "polishing" on screen forever).
    private static func withTimeLimit(_ seconds: TimeInterval, _ work: @escaping @MainActor () async throws -> String) async throws -> String {
        try await withThrowingTaskGroup(of: String?.self) { g in
            g.addTask { @MainActor in try await work() }
            g.addTask {
                try await Task.sleep(for: .seconds(seconds))
                return nil
            }
            defer { g.cancelAll() }
            guard let first = try await g.next(), let out = first else { throw AIError.unavailable("The model took too long to answer") }
            return out
        }
    }

    /// Long text (meeting transcripts) for models with a small context: notes per part, then notes of the notes.
    static func completeLong(_ task: AITask, system: String, prefix: String, text: String) async throws -> String {
        let budget = budget(task, Store.shared.settings)
        if text.count <= budget { return try await complete(task, system: system, user: prefix + text) }
        var parts: [String] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            var piece = rest.prefix(budget)
            if piece.count == budget, let cut = piece.lastIndex(of: "\n"), piece.distance(from: piece.startIndex, to: cut) > budget / 2 { piece = piece[..<cut] }
            parts.append(String(piece))
            rest = rest.dropFirst(piece.count)
        }
        var notes: [String] = []
        for (i, part) in parts.enumerated() {
            notes.append(try await complete(task, system: """
            You condense part \(i + 1) of \(parts.count) of a meeting transcript into short factual bullets: key points, decisions, \
            action items with owners, open questions. Same language as the transcript. Never invent facts.
            """, user: part))
        }
        var joined = notes.enumerated().map { "Part \($0.offset + 1):\n\($0.element)" }.joined(separator: "\n\n")
        if joined.count > budget { joined = String(joined.prefix(budget)) }
        return try await complete(task, system: system, user: "Notes from each part of the meeting, in order:\n\n" + joined)
    }

    private static func stripThinking(_ s: String) -> String {
        s.replacingOccurrences(of: #"<think>[\s\S]*?</think>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func screenText(_ jpeg: Data) async -> String? {
        guard let img = NSImage(data: jpeg), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return await ScreenText.recognize(cg, pointSize: img.size).fullText
    }

    private static func apple(system: String, user: String, temperature: Double, maxTokens: Int, greedy: Bool) async throws -> String {
        if let why = appleStatus { throw AIError.unavailable(why) }
        let session = LanguageModelSession(model: .default, instructions: system)
        let options = GenerationOptions(sampling: greedy ? .greedy : nil, temperature: greedy ? nil : temperature, maximumResponseTokens: maxTokens)
        do {
            return try await session.respond(to: user, options: options).content
        } catch let e as LanguageModelSession.GenerationError {
            switch e {
            case .exceededContextWindowSize: throw AIError.unavailable("Too long for the on-device model. Pick a bigger model for this job in Settings › AI.")
            case .guardrailViolation: throw AIError.unavailable("The on-device model declined this. Try another model in Settings › AI.")
            case .unsupportedLanguageOrLocale: throw AIError.unavailable("The on-device model doesn’t support this language.")
            default: throw AIError.unavailable("On-device model: \(e.localizedDescription)")
            }
        }
    }

    private static func post(_ url: String, body: [String: Any], headers: [String: String], timeout: TimeInterval) async throws -> [String: Any] {
        guard let u = URL(string: url) else { throw AIError.badURL }
        var req = URLRequest(url: u, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch let e as URLError where e.code == .cannotConnectToHost || e.code == .cannotFindHost {
            throw AIError.unavailable("Can’t reach \(u.host ?? url). Is it running?")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let err = json["error"]
            let msg = (err as? [String: Any])?["message"] as? String ?? err as? String ?? String(data: data, encoding: .utf8) ?? ""
            throw AIError.http(status, String(msg.prefix(300)))
        }
        return json
    }

    private static func openAI(_ p: AIProvider, base: String, model: String, system: String, user: String, image: Data?,
                               temperature: Double, maxTokens: Int, reasoning: String, timeout: TimeInterval) async throws -> String {
        var headers: [String: String] = [:]
        if let k = key(p) { headers["Authorization"] = "Bearer \(k)" } else if p.needsKey { throw AIError.noKey(p) }
        if p == .openrouter {
            headers["HTTP-Referer"] = "https://github.com/2dsandwich/Mac-Toolbox"
            headers["X-Title"] = "MONEY!"
        }
        let content: Any = image.map { img -> Any in
            [["type": "text", "text": user], ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + img.base64EncodedString()]]]
        } ?? user
        var body: [String: Any] = ["model": model, "messages": [["role": "system", "content": system], ["role": "user", "content": content]]]
        let reasoningModel = reasoning != "default" || model.hasPrefix("gpt-5") || model.hasPrefix("o3") || model.hasPrefix("o4")
        if p == .openai { body["max_completion_tokens"] = maxTokens } else { body["max_tokens"] = maxTokens }
        if reasoning != "default" { body["reasoning_effort"] = reasoning }
        if !reasoningModel { body["temperature"] = temperature }
        let json = try await post(base + "/chat/completions", body: body, headers: headers, timeout: timeout)
        let msg = ((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]) ?? [:]
        if let text = msg["content"] as? String { return text }
        if let parts = msg["content"] as? [[String: Any]] { return parts.compactMap { $0["text"] as? String }.joined() }
        throw AIError.empty
    }

    private static func ollama(base: String, model: String, system: String, user: String, image: Data?, temperature: Double,
                               maxTokens: Int, o: ProviderSettings, timeout: TimeInterval) async throws -> String {
        var userMsg: [String: Any] = ["role": "user", "content": user]
        if let image { userMsg["images"] = [image.base64EncodedString()] }
        var body: [String: Any] = [
            "model": model, "stream": false, "keep_alive": "\(o.keepAlive)m",
            "messages": [["role": "system", "content": system], userMsg],
            "options": ["temperature": temperature, "num_ctx": o.contextLength, "num_predict": maxTokens],
        ]
        // Qwen 3 thinks out loud by default; off is much faster for these jobs.
        if model.lowercased().hasPrefix("qwen3") { body["think"] = o.thinking }
        let json = try await post(base + "/api/chat", body: body, headers: [:], timeout: max(timeout, 120))
        guard let text = (json["message"] as? [String: Any])?["content"] as? String else { throw AIError.empty }
        return text
    }

    // MARK: Model lists

    /// The models a service offers (Ollama: the ones installed).
    static func listModels(_ p: AIProvider, _ s: Settings) async throws -> [String] {
        let base = baseURL(p, s)
        var urlString = base + "/models"
        if p == .ollama { urlString = base + "/api/tags" }
        guard let url = URL(string: urlString) else { throw AIError.badURL }
        var req = URLRequest(url: url, timeoutInterval: 8)
        if p == .anthropic, let k = key(p) {
            req.setValue(k, forHTTPHeaderField: "x-api-key")
            req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        } else if let k = key(p) {
            req.setValue("Bearer \(k)", forHTTPHeaderField: "Authorization")
        }
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: req)
        } catch {
            throw AIError.unavailable(p.isLocal ? "\(p.short) isn’t running" : error.localizedDescription)
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if p == .ollama { return (json["models"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.sorted() }
        return (json["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }.sorted()
    }

    /// Downloads an open model into Ollama, reporting progress (0…1).
    static func pull(_ model: String, _ s: Settings, progress: @escaping @MainActor (Double, String) -> Void) async throws {
        guard let url = URL(string: baseURL(.ollama, s) + "/api/pull") else { throw AIError.badURL }
        var req = URLRequest(url: url, timeoutInterval: 3600)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
        let (bytes, _) = try await URLSession.shared.bytes(for: req)
        for try await line in bytes.lines {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            if let err = o["error"] as? String { throw AIError.unavailable(err) }
            let status = o["status"] as? String ?? ""
            let total = (o["total"] as? NSNumber)?.doubleValue ?? 0, done = (o["completed"] as? NSNumber)?.doubleValue ?? 0
            progress(total > 0 ? done / total : 0, status)
            if status == "success" { return }
        }
    }
}
