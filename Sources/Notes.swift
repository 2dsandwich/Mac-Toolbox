import AppKit
import Observation
import SwiftUI

/// Sticky notes on a board: paper squares in sticky-note colours, a little crooked, that you drag anywhere,
/// click to write on, recolour, and peel off.
struct StickyNote: Codable, Identifiable, Equatable {
    var id = UUID()
    var text = ""
    var color = 0
    /// Centre on the board, 0…1.
    var x = 0.5
    var y = 0.5
    var tilt = 0.0
    var updated = Date()
}

@MainActor @Observable final class NoteBoard {
    static let shared = NoteBoard()

    /// Back to front (the last one is on top).
    var notes: [StickyNote] = [] { didSet { scheduleSave() } }
    var editing: UUID?
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    /// Off for layout snapshots, so demo notes never reach the real board.
    @ObservationIgnored var persist = true

    static let colors: [(name: String, paper: Color, ink: Color)] = [
        ("Yellow", Color(red: 1.0, green: 0.92, blue: 0.55), Color(red: 0.33, green: 0.27, blue: 0.05)),
        ("Pink", Color(red: 1.0, green: 0.75, blue: 0.82), Color(red: 0.38, green: 0.1, blue: 0.18)),
        ("Blue", Color(red: 0.69, green: 0.86, blue: 1.0), Color(red: 0.07, green: 0.22, blue: 0.38)),
        ("Green", Color(red: 0.74, green: 0.94, blue: 0.7), Color(red: 0.1, green: 0.3, blue: 0.1)),
        ("Orange", Color(red: 1.0, green: 0.8, blue: 0.56), Color(red: 0.4, green: 0.2, blue: 0.04)),
        ("Purple", Color(red: 0.85, green: 0.78, blue: 1.0), Color(red: 0.26, green: 0.15, blue: 0.45)),
    ]

    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MONEY", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("notes.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.url), let saved = try? JSONDecoder().decode([StickyNote].self, from: data) { notes = saved }
    }

    private func scheduleSave() {
        guard persist else { return }
        saveWork?.cancel()
        let snapshot = notes
        let work = DispatchWorkItem {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: Self.url, options: .atomic) }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// A new note, a little down and to the right of the last one (and on top), in the next colour.
    @discardableResult func add(_ text: String = "") -> StickyNote {
        Stats.shared.add(.notes)
        let n = notes.count
        let col = n % 4, row = (n / 4) % 3
        var note = StickyNote(text: text, color: (notes.last.map { $0.color + 1 } ?? 0) % Self.colors.count,
                              x: 0.14 + Double(col) * 0.24 + Double.random(in: -0.02...0.02),
                              y: 0.22 + Double(row) * 0.3 + Double.random(in: -0.02...0.02),
                              tilt: Double.random(in: -3.5...3.5))
        note.updated = Date()
        withAnimation(.spring(duration: 0.4, bounce: 0.35)) { notes.append(note) }
        if text.isEmpty { editing = note.id }
        return note
    }

    func update(_ id: UUID, _ change: (inout StickyNote) -> Void) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        change(&notes[i])
        notes[i].updated = Date()
    }

    func bringToFront(_ id: UUID) {
        guard let i = notes.firstIndex(where: { $0.id == id }), i != notes.count - 1 else { return }
        notes.append(notes.remove(at: i))
    }

    func remove(_ id: UUID) {
        if editing == id { editing = nil }
        withAnimation(.easeIn(duration: 0.18)) { notes.removeAll { $0.id == id } }
    }
}

// MARK: Views

struct NoteBoardView: View {
    let model: LauncherModel
    let board: NoteBoard
    let radius: CGFloat

    static let height: CGFloat = 430
    static let noteSize: CGFloat = 150

    var body: some View {
        let q = model.query.trimmingCharacters(in: .whitespaces)
        GeometryReader { geo in
            ZStack {
                // A soft paper board with a faint dot grid.
                RoundedRectangle(cornerRadius: PanelLayout.inner(radius), style: .continuous).fill(Color.primary.opacity(0.05))
                Canvas { ctx, size in
                    let step: CGFloat = 22
                    for x in stride(from: step, to: size.width, by: step) {
                        for y in stride(from: step, to: size.height, by: step) {
                            ctx.fill(Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)), with: .color(.primary.opacity(0.08)))
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: PanelLayout.inner(radius), style: .continuous))
                .allowsHitTesting(false)
                if board.notes.isEmpty {
                    Image(systemName: "note.text.badge.plus").font(.system(size: 30)).foregroundStyle(.tertiary)
                }
                ForEach(board.notes) { note in
                    StickyNoteView(note: note, board: board, area: geo.size, dimmed: !q.isEmpty && !note.text.localizedCaseInsensitiveContains(q))
                        .transition(.asymmetric(insertion: .scale(scale: 0.6).combined(with: .opacity),
                                                removal: .scale(scale: 0.8, anchor: .bottom).combined(with: .opacity).combined(with: .offset(y: 20))))
                }
            }
            .contentShape(Rectangle())
            // Double-click the board for a new note there.
            .onTapGesture(count: 2) { location in
                let n = board.add()
                board.update(n.id) { $0.x = Double(location.x / geo.size.width); $0.y = Double(location.y / geo.size.height) }
            }
            .onTapGesture { board.editing = nil }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.controlFrames["board"] = $0 }
        }
        .padding(PanelLayout.inset)
        .frame(height: Self.height)
    }
}

private struct StickyNoteView: View {
    let note: StickyNote
    let board: NoteBoard
    let area: CGSize
    let dimmed: Bool
    @State private var drag: CGSize = .zero
    @State private var lifted = false
    @State private var hover = false
    @State private var text = ""
    @FocusState private var focused: Bool

    private var size: CGFloat { NoteBoardView.noteSize }

    var body: some View {
        let c = NoteBoard.colors[note.color % NoteBoard.colors.count]
        let editing = board.editing == note.id
        ZStack(alignment: .topLeading) {
            // Paper, a curled lower-right corner, and a darker glue band along the top.
            Rectangle().fill(c.paper)
            LinearGradient(colors: [.clear, .black.opacity(0.06)], startPoint: .center, endPoint: .bottomTrailing)
            Rectangle().fill(.black.opacity(0.05)).frame(height: 16)
            Group {
                if editing {
                    TextEditor(text: $text)
                        .scrollContentBackground(.hidden)
                        .focused($focused)
                        .onAppear {
                            text = note.text
                            focused = true
                        }
                        .onChange(of: text) { _, v in board.update(note.id) { $0.text = v } }
                } else {
                    Text(note.text)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .font(.custom("Noteworthy", size: 15).weight(.bold))
            .foregroundStyle(c.ink)
            .padding(.horizontal, 10)
            .padding(.top, 20)
            .padding(.bottom, 10)
            if hover || editing { controls(c) }
        }
        .frame(width: size, height: size)
        .clipShape(NoteShape())
        .shadow(color: .black.opacity(lifted ? 0.35 : 0.22), radius: lifted ? 14 : 5, x: 2, y: lifted ? 12 : 4)
        .rotationEffect(.degrees(lifted ? 0 : note.tilt))
        .scaleEffect(lifted ? 1.06 : 1)
        .opacity(dimmed ? 0.35 : 1)
        // Never past the board's edges (a tilted note keeps a little margin too).
        .position(x: min(max(size / 2 + 6, CGFloat(note.x) * area.width), area.width - size / 2 - 6) + drag.width,
                  y: min(max(size / 2 + 6, CGFloat(note.y) * area.height), area.height - size / 2 - 6) + drag.height)
        .onHover { hover = $0 }
        .onTapGesture {
            board.bringToFront(note.id)
            board.editing = note.id
        }
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { v in
                    if !lifted {
                        withAnimation(.spring(duration: 0.25)) { lifted = true }
                        board.bringToFront(note.id)
                    }
                    drag = v.translation
                }
                .onEnded { v in
                    let half = size / 2
                    let x = min(area.width - half, max(half, CGFloat(note.x) * area.width + v.translation.width)) / max(area.width, 1)
                    let y = min(area.height - half, max(half, CGFloat(note.y) * area.height + v.translation.height)) / max(area.height, 1)
                    withAnimation(.spring(duration: 0.35, bounce: 0.3)) {
                        board.update(note.id) { $0.x = Double(x); $0.y = Double(y); $0.tilt = Double.random(in: -3.5...3.5) }
                        drag = .zero
                        lifted = false
                    }
                }
        )
        .onChange(of: board.editing) { _, id in if id != note.id { focused = false } }
    }

    /// Colours and peel-off, along the glue band.
    private func controls(_ c: (name: String, paper: Color, ink: Color)) -> some View {
        HStack(spacing: 4) {
            ForEach(NoteBoard.colors.indices, id: \.self) { i in
                Button { board.update(note.id) { $0.color = i } } label: {
                    Circle().fill(NoteBoard.colors[i].paper)
                        .overlay(Circle().strokeBorder(c.ink.opacity(i == note.color ? 0.8 : 0.25), lineWidth: i == note.color ? 1.5 : 0.5))
                        .frame(width: 11, height: 11)
                }
                .buttonStyle(.plain)
                .help(NoteBoard.colors[i].name)
            }
            Spacer(minLength: 0)
            Button { board.remove(note.id) } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(c.ink.opacity(0.7))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Peel off")
        }
        .padding(.horizontal, 6)
        .frame(height: 16)
        .transition(.opacity)
    }
}

/// A square of paper with its lower-right corner lifting slightly.
private struct NoteShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let curl: CGFloat = 10
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - curl))
        p.addQuadCurve(to: CGPoint(x: r.maxX - curl * 1.6, y: r.maxY), control: CGPoint(x: r.maxX - 1, y: r.maxY - 2))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}
