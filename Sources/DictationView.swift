import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// The Dictation view: every dictation with its raw and polished words (paste, copy, polish again), your speed this
/// week, anything dictation still needs, and audio or video files dropped in to transcribe.
struct DictationPanel: View {
    let model: LauncherModel
    let s: Settings
    let radius: CGFloat
    @State private var history = DictationHistory.shared
    @State private var dropping = false

    var body: some View {
        let list = history.search(model.query)
        let current = history.current(in: list)
        let empty = list.isEmpty && history.job == nil
        VStack(spacing: PanelLayout.gap) {
            header(empty ? (history.entries.isEmpty ? "No dictations yet" + Self.howTo(s) : "No matches") : nil)
            ForEach(DictationSetup.missing(), id: \.self) { SetupRow(need: $0) }
            if !empty {
                HStack(spacing: 0) {
                    rows(list, current)
                        .frame(width: model.width(s) * 0.4)
                    Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1).padding(.vertical, 6)
                    if let current {
                        EntryDetail(entry: current, history: history).id(current.id)
                    } else {
                        Spacer()
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(PanelLayout.edges)
        .frame(height: Self.height(model, s))
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: PanelLayout.inner(radius), style: .continuous)
                    .strokeBorder(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .padding(PanelLayout.gap)
                    .overlay { Image(systemName: "waveform.badge.plus").font(.system(size: 34)).foregroundStyle(.white.opacity(0.8)) }
                    .background(RoundedRectangle(cornerRadius: PanelLayout.inner(radius), style: .continuous).fill(.black.opacity(0.4)).padding(PanelLayout.gap))
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in DictationHistory.shared.transcribe(url) } }
            }
            return true
        }
    }

    /// Nothing to list: just the header row (saying so) and anything dictation still needs.
    static func height(_ model: LauncherModel, _ s: Settings) -> CGFloat {
        let h = DictationHistory.shared
        guard h.search(model.query).isEmpty, h.job == nil else { return Metrics.clipboardList(s) }
        return PanelLayout.vertical + 32 + CGFloat(DictationSetup.missing().count) * (34 + PanelLayout.gap)
    }

    /// How to start, from the keys set in Settings › Dictation.
    static func howTo(_ s: Settings) -> String {
        let keys = (s.fnDictation ? ["hold Fn"] : []) + (s.dictationHotKey.isEmpty ? [] : ["press \(s.dictationHotKey.display)"])
        return !s.dictationEnabled || keys.isEmpty ? "" : ". To dictate, " + keys.joined(separator: " or ") + "."
    }

    /// This week's numbers, or `message` when there's nothing to list.
    private func header(_ message: String?) -> some View {
        let sum = history.summary
        return HStack(spacing: 18) {
            if let message {
                Text(message).font(.system(size: 13)).foregroundStyle(.secondary)
            } else if sum.words > 0 {
                stat(sum.words.formatted(), "words this week")
                stat("\(sum.wpm)", "wpm")
                stat("\(sum.streak)", "day streak")
            }
            Spacer(minLength: 0)
            ClockButton(symbol: "waveform.badge.plus", help: "Transcribe an audio or video file") {
                (NSApp.delegate as? AppDelegate)?.launcher.hide()
                history.openFile()
            }
        }
        .padding(.leading, 12)
        .frame(height: 32)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(value).font(.system(size: 15, weight: .semibold).monospacedDigit())
            Text(label).font(.system(size: 12.5)).foregroundStyle(.secondary)
        }
    }

    private func rows(_ list: [DictationEntry], _ current: DictationEntry?) -> some View {
        let rowRadius = max(4, min(radius - PanelLayout.inset, s.rowSize / 2))
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: Metrics.rowGap * 2) {
                    if let job = history.job { JobRow(name: job.name, progress: job.progress, height: s.rowSize, radius: rowRadius) }
                    ForEach(list) { e in
                        EntryRow(entry: e, selected: e.id == current?.id, height: s.rowSize, radius: rowRadius)
                            .id(e.id)
                            .onTapGesture(count: 2) { (NSApp.delegate as? AppDelegate)?.launcher.pasteDictation(e.text) }
                            .onTapGesture { history.selected = e.id; history.showRaw = false }
                    }
                }
                .padding(.trailing, PanelLayout.gap)
            }
            .scrollIndicators(.never)
            .onChange(of: history.selected) { _, id in if let id { proxy.scrollTo(id) } }
        }
    }
}

/// What dictation still needs before it can work: microphone, Accessibility (to type for you), a speech model.
@MainActor enum DictationSetup {
    enum Need: String, Hashable { case microphone, accessibility, model }
    /// Snapshots show a fixed set (`--setup`: all of them), whatever this Mac has allowed.
    static var shown: [Need]?

    static func missing() -> [Need] {
        if let shown { return shown }
        var out: [Need] = []
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized { out.append(.microphone) }
        if !Paster.trusted { out.append(.accessibility) }
        let models = SpeechModels.shared, listen = Store.shared.settings.listenLocales
        // Only once the models have been looked up (an empty status is "not checked yet").
        if listen.contains(where: { models.status[$0] != nil }), !listen.contains(where: models.isInstalled) { out.append(.model) }
        return out
    }
}

private struct SetupRow: View {
    let need: DictationSetup.Need
    private let coral = Color(red: 1, green: 106 / 255, blue: 85 / 255)

    var body: some View {
        let (symbol, title, button): (String, String, String) = switch need {
        case .microphone: ("mic.slash", "MONEY! can't hear the microphone", "Allow")
        case .accessibility: ("keyboard", "MONEY! can't type for you", "Allow")
        case .model: ("arrow.down.circle", "No speech model on this Mac", "Download")
        }
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(coral).frame(width: 16)
            Text(title).font(.system(size: 12.5))
            Spacer(minLength: 0)
            Button(action: act) {
                Text(button).font(.system(size: 12.5)).foregroundStyle(.primary)
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(Capsule().fill(Color.primary.opacity(0.12)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 12).padding(.trailing, 3)
        .frame(height: 34)
        .background(Capsule().fill(coral.opacity(0.14)))
    }

    private func act() {
        switch need {
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                Task { _ = await MicCapture.requestAccess() }
            } else {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            }
        case .accessibility:
            Paster.requestAccess()
        case .model:
            let s = Store.shared.settings
            s.listenLocales.filter { !SpeechModels.shared.isInstalled($0) }.forEach(SpeechModels.shared.download)
        }
    }
}

private struct EntryRow: View {
    let entry: DictationEntry
    let selected: Bool
    let height: CGFloat
    let radius: CGFloat
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            EntryIcon(entry: entry).frame(width: 20, height: 20)
            Text(entry.kind == .file ? entry.app : entry.text.split(whereSeparator: \.isNewline).joined(separator: " "))
                .font(.system(size: 13.5)).lineLimit(2)
            Spacer(minLength: 4)
            Text(shortAge(entry.date)).font(.system(size: 11.5)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(selected ? selectedFill : hover ? hoverFill : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

private struct EntryIcon: View {
    let entry: DictationEntry
    var body: some View {
        if entry.kind != .file, !entry.bundleID.isEmpty, let img = IconCache.icon(forBundleID: entry.bundleID) {
            Image(nsImage: img).resizable()
        } else {
            Image(systemName: entry.kind == .file ? "waveform" : entry.kind == .voiceEdit ? "wand.and.stars" : "mic.fill")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
        }
    }
}

private struct JobRow: View {
    let name: String
    let progress: Double
    let height: CGFloat
    let radius: CGFloat

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 5) {
                Text(name).font(.system(size: 13.5)).lineLimit(1)
                GeometryReader { g in
                    Capsule().fill(Color.primary.opacity(0.12))
                        .overlay(alignment: .leading) { Capsule().fill(Color.white).frame(width: max(4, g.size.width * progress)) }
                }
                .frame(height: 3)
                .animation(.smooth(duration: 0.3), value: progress)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(hoverFill))
    }
}

private struct EntryDetail: View {
    let entry: DictationEntry
    let history: DictationHistory

    var body: some View {
        let raw = history.showRaw && entry.polished
        let busy = history.retrying == entry.id
        VStack(alignment: .leading, spacing: PanelLayout.gap) {
            if entry.polished {
                VersionSwitch(raw: raw) { history.showRaw = $0 }
            }
            ScrollView(.vertical) {
                Text(raw ? entry.raw : entry.text)
                    .font(.system(size: 14))
                    .foregroundStyle(raw ? Color.secondary : Color.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .opacity(busy ? 0.4 : 1)
                    .animation(.smooth(duration: 0.2), value: raw)
            }
            .scrollIndicators(.never)
            .overlay { if busy { ThinkingDots().colorMultiply(.primary) } }
            .frame(maxHeight: .infinity, alignment: .top)
            Text(details).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 6) {
                let text = raw ? entry.raw : entry.text
                ClockButton(symbol: "arrow.turn.down.left", help: "Paste (↩)") { (NSApp.delegate as? AppDelegate)?.launcher.pasteDictation(text) }
                ClockButton(symbol: "doc.on.doc", help: "Copy") { (NSApp.delegate as? AppDelegate)?.launcher.copyDictation(text) }
                if entry.kind == .dictation {
                    ClockButton(symbol: "sparkles", help: "Polish again") { (NSApp.delegate as? AppDelegate)?.dictation.repolish(entry.id) }
                        .disabled(busy)
                }
                if entry.kind == .file {
                    ClockButton(symbol: "captions.bubble", help: "Save subtitles (.srt)") { exportLater(subtitles: true) }
                    ClockButton(symbol: "square.and.arrow.down", help: "Save text (.txt)") { exportLater(subtitles: false) }
                }
                Spacer(minLength: 0)
                ClockButton(symbol: "trash", help: "Delete") { history.delete(entry.id) }
            }
        }
        .padding(.leading, PanelLayout.inset)
        .padding(.top, 4)
    }

    /// The popup goes first (a save window in front of it would close it anyway).
    private func exportLater(subtitles: Bool) {
        let e = entry
        (NSApp.delegate as? AppDelegate)?.launcher.hide()
        DispatchQueue.main.async { DictationHistory.shared.export(e, subtitles: subtitles) }
    }

    private var details: String {
        var parts = [entry.app.isEmpty ? (entry.kind == .file ? "File" : "Dictation") : entry.app]
        parts.append(entry.date.formatted(.relative(presentation: .named)))
        if entry.kind == .file {
            parts.append(Duration.seconds(entry.seconds).formatted(.time(pattern: entry.seconds >= 3600 ? .hourMinuteSecond : .minuteSecond)))
        }
        parts.append("\(entry.words) words")
        if entry.kind == .dictation, entry.seconds > 1 { parts.append("\(Int(Double(entry.words) / entry.seconds * 60)) wpm") }
        if let c = Prompts.WritingContext(rawValue: entry.context), entry.kind == .dictation { parts.append(c.title) }
        return parts.joined(separator: " · ")
    }
}

/// Polished · Original, on a sliding pill.
private struct VersionSwitch: View {
    let raw: Bool
    let pick: (Bool) -> Void
    private let segment: CGFloat = 76

    var body: some View {
        HStack(spacing: 0) {
            ForEach([false, true], id: \.self) { r in
                Button { pick(r) } label: {
                    Text(r ? "Original" : "Polished").font(.system(size: 12.5, weight: r == raw ? .semibold : .regular))
                        .foregroundStyle(r == raw ? Color.primary : Color.secondary)
                        .frame(width: segment, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.15)).frame(width: segment).offset(x: raw ? segment : 0)
                .animation(.interpolatingSpring(mass: 1, stiffness: 420, damping: 36), value: raw)
        }
        .padding(4)
        .background(Capsule().fill(Color.primary.opacity(0.1)))
    }
}

extension Prompts.WritingContext {
    /// How the Dictation view names where the words went.
    var title: String {
        switch self {
        case .prompt: "AI prompt"
        case .email: "Email"
        case .chat: "Message"
        case .document: "Notes"
        case .code: "Code"
        case .search: "Search"
        case .plain: "Text"
        }
    }
}
