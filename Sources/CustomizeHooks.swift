import AppKit
import SwiftUI

/// Off-screen checks for the text settings and the AI services. Nothing goes over the network and no key is read.
/// `--providers-test`: each service's request (address, key header, body) and model-list parsing, on canned JSON.
/// `--fonts-test`: untouched settings give the exact fonts used before; a changed family, size and weight reach them.
/// `--font-picker-snapshot <png> [--search text]`: the font list, drawn off screen.
extension AppDelegate {
    func runCustomizeHook(_ args: [String]) -> Bool {
        if args.contains("--providers-test") {
            Task { exit(await providersTest() ? 0 : 1) }
            return true
        }
        if args.contains("--fonts-test") {
            store.persist = false
            exit(fontsTest() ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--font-picker-snapshot"), i + 1 < args.count {
            let search = args.firstIndex(of: "--search").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            let hv = NSHostingView(rootView: FontPicker(current: "rounded", allowsSame: true, initialSearch: search ?? "") { _ in }
                .background(Color(white: 0.16)).environment(\.colorScheme, .dark))
            let w = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 280, height: 360), styleMask: .borderless, backing: .buffered, defer: false)
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = .windowBackgroundColor
            w.contentView = hv
            w.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            if let rep = hv.bitmapImageRepForCachingDisplay(in: hv.bounds) {
                hv.cacheDisplay(in: hv.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
            }
            exit(0)
        }
        return false
    }

    /// Scrolls the settings page (the widest scroll view, not the sidebar) for `--settings-snapshot … --scroll <y>`.
    func scrollSettings(to y: Double) {
        func scrolls(_ v: NSView) -> [NSScrollView] { ((v as? NSScrollView).map { [$0] } ?? []) + v.subviews.flatMap(scrolls) }
        guard let root = settingsWindow?.contentView,
              let page = scrolls(root).filter({ $0.frame.width > 300 }).max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }) else { return }
        page.contentView.scroll(to: NSPoint(x: 0, y: y))
        page.reflectScrolledClipView(page.contentView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    }

    private func check(_ ok: Bool, _ what: String) -> Bool {
        print(ok ? "ok  " : "FAIL", what)
        return ok
    }

    private func providersTest() async -> Bool {
        var ok = true
        let s = Settings()
        func body(_ r: URLRequest) -> [String: Any] { (try? JSONSerialization.jsonObject(with: r.httpBody ?? Data())) as? [String: Any] ?? [:] }

        // Requests: every OpenAI-compatible service, with a made-up key.
        for p in AIProvider.allCases where ![.apple, .anthropic, .ollama].contains(p) {
            let model = p.suggestedModels.first ?? "local-model"
            guard let r = try? AI.openAIRequest(p, base: AI.baseURL(p, s), model: model, system: "sys", user: "hi", image: nil, temperature: 0.2,
                                                maxTokens: 100, reasoning: "default", key: "test-key", timeout: 10) else {
                ok = check(false, "\(p.short): request") && ok
                continue
            }
            let b = body(r)
            ok = check(r.url?.absoluteString == AI.baseURL(p, s) + "/chat/completions" && r.httpMethod == "POST"
                       && r.value(forHTTPHeaderField: "Authorization") == "Bearer test-key" && b["model"] as? String == model
                       && (b["messages"] as? [[String: Any]])?.count == 2, "\(p.short): \(r.url?.absoluteString ?? "")") && ok
        }
        let missing = (try? AI.openAIRequest(.groq, base: "https://x", model: "m", system: "", user: "", image: nil, temperature: 0, maxTokens: 1,
                                             reasoning: "default", key: nil, timeout: 1)) == nil
        ok = check(missing, "a service that needs a key refuses without one") && ok
        if let r = try? AI.openAIRequest(.openai, base: "https://api.openai.com/v1", model: "gpt-5-mini", system: "s", user: "u", image: Data([1, 2]),
                                         temperature: 0.4, maxTokens: 50, reasoning: "default", key: "k", timeout: 5) {
            let b = body(r), parts = ((b["messages"] as? [[String: Any]])?.last?["content"] as? [[String: Any]]) ?? []
            ok = check(b["max_completion_tokens"] as? Int == 50 && b["temperature"] == nil && parts.count == 2, "OpenAI: reasoning model, image part") && ok
        }
        if let r = try? AI.openAIRequest(.openrouter, base: AI.baseURL(.openrouter, s), model: "openai/gpt-5", system: "s", user: "u", image: nil,
                                         temperature: 0.4, maxTokens: 50, reasoning: "default", key: "k", timeout: 5) {
            ok = check(body(r)["temperature"] == nil && r.value(forHTTPHeaderField: "X-Title") == "MONEY!", "OpenRouter: openai/gpt-5 is a reasoning model") && ok
        }
        if let r = try? AI.ollamaRequest(base: "http://localhost:11434", model: "qwen3:4b", system: "s", user: "u", image: nil, temperature: 0,
                                         maxTokens: 10, o: ProviderSettings(), timeout: 5) {
            ok = check(r.url?.path == "/api/chat" && body(r)["think"] as? Bool == false, "Ollama: /api/chat, thinking off") && ok
        }

        // Model lists.
        func models(_ p: AIProvider, _ json: String) -> [String] { AI.parseModels(p, Data(json.utf8)) }
        ok = check(models(.openai, #"{"data":[{"id":"gpt-5"},{"id":"gpt-5-mini"}]}"#) == ["gpt-5", "gpt-5-mini"], "OpenAI list") && ok
        ok = check(models(.openrouter, #"{"data":[{"id":"openai/gpt-5"},{"id":"meta-llama/llama-3.3-70b-instruct:free"}]}"#).first == "meta-llama/llama-3.3-70b-instruct:free",
                   "OpenRouter list: free models first") && ok
        ok = check(models(.gemini, #"{"object":"list","data":[{"id":"models/gemini-2.5-flash"}]}"#) == ["gemini-2.5-flash"], "Gemini list") && ok
        ok = check(models(.github, #"[{"id":"openai/gpt-4.1","name":"GPT-4.1"},{"id":"meta/Llama-3.3-70B-Instruct"}]"#).count == 2, "GitHub catalog") && ok
        ok = check(models(.ollama, #"{"models":[{"name":"qwen3:4b"},{"name":"gemma3:4b"}]}"#) == ["gemma3:4b", "qwen3:4b"], "Ollama list") && ok
        ok = check(models(.groq, "not json").isEmpty, "a bad reply gives no models") && ok
        let gh = try? AI.modelsRequest(.github, base: AIProvider.github.defaultBaseURL, key: "k")
        ok = check(gh?.url?.absoluteString == "https://models.github.ai/catalog/models", "GitHub lists from its catalog") && ok
        let an = try? AI.modelsRequest(.anthropic, base: AIProvider.anthropic.defaultBaseURL, key: "k")
        ok = check(an?.value(forHTTPHeaderField: "x-api-key") == "k", "Anthropic list uses x-api-key") && ok

        // The whole path (Test button) on canned replies: nothing goes out.
        var sent: [URL] = []
        AI.canned = { req in
            sent.append(req.url!)
            if req.url!.path.hasSuffix("/api/chat") { return (Data(#"{"message":{"content":"OK"}}"#.utf8), 200) }
            if req.url!.path.hasSuffix("/models") { return (Data(#"{"data":[{"id":"local-a"},{"id":"local-b"}]}"#.utf8), 200) }
            return (Data(#"{"choices":[{"message":{"content":"<think>hm</think>OK"}}]}"#.utf8), 200)
        }
        let lm = try? await AI.ping(.lmstudio, model: "local-a", s)
        ok = check(lm == "OK", "LM Studio test answers (thinking stripped)") && ok
        let ol = try? await AI.ping(.ollama, model: "qwen3:4b", s)
        ok = check(ol == "OK", "Ollama test answers") && ok
        let list = try? await AI.listModels(.lmstudio, s)
        ok = check(list == ["local-a", "local-b"], "LM Studio model list") && ok
        AI.canned = { _ in (Data(#"{"error":{"message":"Invalid key"}}"#.utf8), 401) }
        do { _ = try await AI.ping(.custom, model: "m", s); ok = check(false, "an error reply fails") && ok }
        catch { ok = check(error.localizedDescription.contains("401"), "an error reply fails: \(error.localizedDescription)") && ok }
        ok = check(sent.allSatisfy { $0.host == "localhost" }, "only canned localhost requests") && ok
        AI.canned = nil

        // Free and vision flags.
        ok = check(AIProvider.allCases.filter(\.isFree).map(\.short) == ["On-device", "Ollama", "LM Studio", "OpenRouter", "Groq", "Gemini", "Mistral", "GitHub"],
                   "free choices") && ok
        ok = check(AIProvider.github.seesImages("openai/gpt-4.1") && !AIProvider.groq.seesImages("llama-3.3-70b-versatile")
                   && AIProvider.ollama.seesImages("gemma3:4b"), "vision flags") && ok
        var v = Settings()
        v.aiTasks[AITask.vision.rawValue] = TaskModel(provider: .gemini, model: "gemini-2.5-flash")
        ok = check(AI.seesImages(.vision, v), "the image job asks its service for images") && ok
        print(ok ? "providers: all passed" : "providers: FAILED")
        return ok
    }

    private func fontsTest() -> Bool {
        var ok = true
        store.settings = Settings()
        ok = check(Fonts.systemScale == 1, "system text size is the usual 13 pt (\(NSFont.preferredFont(forTextStyle: .body).pointSize))") && ok
        for area in TextArea.allCases {
            ok = check(Fonts.ns(area, 15) == NSFont.systemFont(ofSize: 15) && Fonts.ns(area, 12.5, weight: .semibold) == NSFont.systemFont(ofSize: 12.5, weight: .semibold),
                       "\(area.title): untouched is the system font") && ok
        }
        ok = check(Font.app(.rows, 15) == .system(size: 15, weight: .regular, design: .default), "untouched SwiftUI font is the same") && ok
        store.settings.fontFamily = "serif"
        store.settings.textStyles["rows"] = TextStyle(family: "Menlo", scale: 1.2, weight: "bold")
        let serif = Fonts.ns(.bar, 20)
        ok = check(serif.fontDescriptor.symbolicTraits.contains(.classModernSerifs) || serif.fontName.lowercased().contains("serif") || serif.familyName != NSFont.systemFont(ofSize: 20).familyName,
                   "main font serif reaches the bar: \(serif.fontName)") && ok
        let rows = Fonts.ns(.rows, 15)
        ok = check(rows.familyName == "Menlo" && rows.pointSize == 18 && rows.fontName.contains("Bold"), "rows: Menlo Bold 18: \(rows.fontName) \(rows.pointSize)") && ok
        store.settings.fontFamily = "Times New Roman"
        ok = check(Fonts.ns(.notch, 14).familyName == "Times New Roman", "an installed family reaches the notch") && ok
        store.settings.fontFamily = "No Such Font"
        ok = check(Fonts.ns(.notch, 14) == NSFont.systemFont(ofSize: 14), "a missing family falls back to the system font") && ok
        ok = check(!Fonts.families.isEmpty && Fonts.families.contains("Menlo"), "installed families listed (\(Fonts.families.count))") && ok
        print(ok ? "fonts: all passed" : "fonts: FAILED")
        return ok
    }
}
