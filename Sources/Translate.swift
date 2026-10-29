import AppKit
import AVFoundation
import Observation
import SwiftUI

/// The Translate mode: type in the bar, the translation follows (a moment after you stop typing).
@MainActor @Observable final class Translator {
    static let shared = Translator()
    static let languages = ["Auto", "English", "Japanese", "Simplified Chinese", "Traditional Chinese", "Korean", "French", "Spanish", "German",
                            "Italian", "Portuguese", "Thai", "Vietnamese", "Indonesian", "Russian", "Arabic"]

    /// "Auto": Japanese ↔ English, whichever the text isn't.
    var target = "Auto"
    /// What it's written in ("Auto": guessed from the text).
    var source = "Auto"
    @ObservationIgnored private let voice = AVSpeechSynthesizer()

    /// BCP-47 codes, for reading aloud.
    static let codes: [String: String] = [
        "English": "en-US", "Japanese": "ja-JP", "Simplified Chinese": "zh-CN", "Traditional Chinese": "zh-TW", "Chinese": "zh-CN",
        "Korean": "ko-KR", "French": "fr-FR", "Spanish": "es-ES", "German": "de-DE", "Italian": "it-IT", "Portuguese": "pt-BR",
        "Thai": "th-TH", "Vietnamese": "vi-VN", "Indonesian": "id-ID", "Russian": "ru-RU", "Arabic": "ar-SA",
    ]

    func speak(_ text: String, in language: String) {
        voice.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: Self.codes[language] ?? "en-US")
        voice.speak(u)
    }

    func sourceLanguage(_ text: String) -> String { source == "Auto" ? Self.detect(text) : source }
    var result: String?
    var busy = false
    var error: String?
    @ObservationIgnored private var work: DispatchWorkItem?
    @ObservationIgnored private var cache: [String: String] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lastText = ""

    /// A rough guess at the language of `text` (enough to pick a direction).
    static func detect(_ text: String) -> String {
        let u = text.unicodeScalars
        if u.contains(where: { (0x3040...0x30FF).contains($0.value) }) { return "Japanese" }
        if u.contains(where: { (0xAC00...0xD7AF).contains($0.value) }) { return "Korean" }
        if u.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) { return "Chinese" }
        if u.contains(where: { (0x0E00...0x0E7F).contains($0.value) }) { return "Thai" }
        if u.contains(where: { (0x0400...0x04FF).contains($0.value) }) { return "Russian" }
        if u.contains(where: { (0x0600...0x06FF).contains($0.value) }) { return "Arabic" }
        return "English"
    }

    func resolvedTarget(_ text: String) -> String {
        guard target == "Auto" else { return target }
        return sourceLanguage(text) == "English" ? "Japanese" : "English"
    }

    func request(_ raw: String, now: Bool = false) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lang = resolvedTarget(text)
        let from = source == "Auto" ? "" : " from \(source)"
        let key = "\(source)>\(lang)|\(text)"
        guard key != lastText || error != nil else { return }
        lastText = key
        work?.cancel()
        generation += 1
        let gen = generation
        guard !text.isEmpty else {
            result = nil
            busy = false
            error = nil
            return
        }
        if let hit = cache[key] {
            result = hit
            busy = false
            error = nil
            return
        }
        busy = true
        error = nil
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                Task { @MainActor in
                    do {
                        let out = try await AI.complete(.translate, system: """
                        You translate text\(from) into \(lang). Keep the meaning, tone and formatting, and make it sound natural rather than literal. \
                        Reply with the translation only: no quotes, notes, or romanization.
                        """, user: text)
                        guard let self, gen == self.generation else { return }
                        self.cache[key] = out
                        self.result = out
                    } catch {
                        guard let self, gen == self.generation else { return }
                        self.error = error.localizedDescription
                    }
                    if let self, gen == self.generation { self.busy = false }
                }
            }
        }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + (now ? 0 : 0.6), execute: item)
    }

    /// Swap: the languages change places, and the translation becomes the text (translated back the other way).
    func swapped(_ text: String) -> String? {
        let from = sourceLanguage(text), to = resolvedTarget(text)
        source = to
        target = from == "Chinese" ? "Simplified Chinese" : from
        guard let r = result, !r.isEmpty else { return nil }
        return r
    }
}

/// Translate, like Apple's: the two languages on top (swap between them), the words you type in the bar, and the
/// translation big underneath, ready to copy (↩) or hear.
struct TranslateView: View {
    let model: LauncherModel
    let translator: Translator
    let radius: CGFloat

    static let barHeight: CGFloat = 44
    static let resultHeight: CGFloat = 176
    static var height: CGFloat { PanelLayout.inset * 2 + PanelLayout.gap + barHeight + resultHeight }

    var body: some View {
        let text = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let from = translator.sourceLanguage(text), to = translator.resolvedTarget(text)
        VStack(spacing: PanelLayout.gap) {
            HStack(spacing: PanelLayout.gap) {
                languageMenu(title: translator.source == "Auto" ? (text.isEmpty ? "Detect" : from) : from,
                             auto: translator.source == "Auto" && !text.isEmpty, current: translator.source, autoTitle: "Detect Language") { translator.source = $0 }
                Button {
                    withAnimation(.spring(duration: 0.35, bounce: 0.3)) {
                        if let back = translator.swapped(text) { model.setQuery(back) } else { translator.request(model.query, now: true) }
                    }
                } label: {
                    Image(systemName: "arrow.left.arrow.right").font(.system(size: 13, weight: .semibold))
                        .frame(width: Self.barHeight, height: Self.barHeight)
                        .background(Circle().fill(Color.primary.opacity(0.1)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Swap languages")
                languageMenu(title: to, auto: translator.target == "Auto", current: translator.target, autoTitle: "Auto (Japanese ↔ English)") { translator.target = $0 }
            }
            .frame(height: Self.barHeight)
            Block(radius: radius) {
                VStack(alignment: .leading, spacing: 0) {
                    ScrollView(.vertical) {
                        Group {
                            if let err = translator.error {
                                Label(err, systemImage: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundStyle(.orange)
                            } else if let r = translator.result, !text.isEmpty {
                                Text(r).font(.system(size: 22, weight: .medium)).textSelection(.enabled)
                                    .opacity(translator.busy ? 0.4 : 1)
                                    .contentTransition(.opacity)
                            } else if translator.busy {
                                ThinkingDots().colorMultiply(.primary)
                            } else {
                                Image(systemName: "character.bubble").font(.system(size: 30)).foregroundStyle(.quaternary)
                                    .frame(maxWidth: .infinity, minHeight: 110)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .animation(.smooth(duration: 0.2), value: translator.result)
                    }
                    .scrollIndicators(.never)
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        if let r = translator.result, !text.isEmpty, translator.error == nil {
                            ClockButton(symbol: "speaker.wave.2.fill", help: "Listen") { translator.speak(r, in: to) }
                            ClockButton(symbol: "doc.on.doc", help: "Copy (↩)") { (NSApp.delegate as? AppDelegate)?.launcher.copyTranslation(r) }
                        }
                    }
                    .frame(height: 34)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .frame(height: Self.resultHeight)
        }
        .padding(PanelLayout.inset)
        .onChange(of: translator.source) { _, _ in translator.request(model.query, now: true) }
        .onChange(of: translator.target) { _, _ in translator.request(model.query, now: true) }
    }

    /// A language, as a wide pill that opens the list.
    private func languageMenu(title: String, auto: Bool, current: String, autoTitle: String, pick: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(Translator.languages, id: \.self) { lang in
                Button {
                    pick(lang)
                } label: {
                    if lang == current { Label(lang == "Auto" ? autoTitle : lang, systemImage: "checkmark") } else { Text(lang == "Auto" ? autoTitle : lang) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                if auto { Image(systemName: "sparkles").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary) }
                Text(title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: PanelLayout.inner(radius), style: .continuous).fill(Color.primary.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }
}
