import AppKit
import Observation

// The notch's shelf: files dropped on it wait there to be dragged out, AirDropped, shared or opened. Also what feeds it:
// a file dragged over the notch from another app, and new files in ~/Downloads.

/// Files kept on the shelf, by reference: bookmarks in `~/Library/Application Support/MONEY/shelf.json`, so a file moved
/// or renamed is still found, and one deleted drops off. Nothing is copied.
@MainActor @Observable final class Shelf {
    static let shared = Shelf()
    /// Oldest first, at most `limit` (that many rows fit the open notch).
    private(set) var files: [URL] = [] {
        didSet {
            save()
            onChange?()
        }
    }
    static let limit = 10
    @ObservationIgnored var onChange: (() -> Void)?
    /// Off for snapshots and tests: they never read or write the real shelf.
    @ObservationIgnored private let persist = !CommandLine.arguments.contains { $0.hasSuffix("-snapshot") || $0.hasSuffix("-test") }

    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MONEY", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("shelf.json")
    }

    private init() {
        guard persist, let data = try? Data(contentsOf: Self.url), let marks = try? JSONDecoder().decode([Data].self, from: data) else { return }
        files = marks.compactMap { mark in
            var stale = false
            return try? URL(resolvingBookmarkData: mark, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale)
        }
        .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Added at the end (one already there moves to the end); the oldest go past the limit.
    func add(_ urls: [URL]) {
        let new = urls.filter(\.isFileURL).map(\.standardizedFileURL)
        guard !new.isEmpty else { return }
        files = Array((files.filter { !new.contains($0) } + new).suffix(Self.limit))
    }

    func remove(_ url: URL) { files.removeAll { $0 == url } }
    func clear() { files = [] }

    static func airDrop(_ urls: [URL]) { NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls) }

    private func save() {
        guard persist else { return }
        let marks = files.compactMap { try? $0.bookmarkData() }
        if let data = try? JSONEncoder().encode(marks) { try? data.write(to: Self.url, options: .atomic) }
    }
}

/// A file dragged from another app: when it comes over the notch, the notch opens with the shelf as a drop target. The
/// panel takes the pointer only over its open shape, so it must open before the drop can land. Looks at the drag
/// pasteboard's types (never its contents), and only once per drag, when the pointer first reaches the notch.
@MainActor final class FileDragWatch {
    private let island: IslandModel
    private var monitor: Any?
    private var downCount = 0
    /// This drag carries files (nil until its drag session starts).
    private var files: Bool?
    /// The dragged file came within reach of the notch, which opened.
    private var near = false
    /// How far from the notch (points) a dragged file opens the shelf.
    static let reach: CGFloat = 140
    /// While a file drag is on: checks for the button coming up (the drag's own mouse-up goes to the app it's dropped on).
    private var ending: Timer?

    init(island: IslandModel) { self.island = island }

    func start() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged]) { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
        }
    }

    /// A file drag is told apart from other drags (selecting text, moving a window) by the drag pasteboard changing after
    /// the button went down; once it carries files, the notch opens as the drop target straight away.
    private func handle(_ e: NSEvent) {
        if e.type == .leftMouseDown {
            downCount = NSPasteboard(name: .drag).changeCount
            files = nil
            return
        }
        guard Store.shared.settings.notchShelf else { return }
        if files == nil {
            let pb = NSPasteboard(name: .drag)
            guard pb.changeCount != downCount else { return } // no drag session yet: asked again on the next move
            files = pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            guard files == true else { return }
            island.fileDragged(over: false) // the closed notch shows the shelf's tray while files are dragged
        }
        guard files == true else { return }
        // The shelf opens only once the file comes within reach of the notch, not as soon as a drag starts.
        if !near, island.dropZone.insetBy(dx: -Self.reach, dy: -Self.reach).contains(NSEvent.mouseLocation) {
            near = true
            island.fileDragged(over: true)
        }
        guard ending == nil else { return }
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, NSEvent.pressedMouseButtons & 1 == 0 else { return }
                self.ending?.invalidate()
                self.ending = nil
                self.files = nil
                self.near = false
                self.island.fileDragEnded()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        ending = t
    }

}

/// New files in a folder (~/Downloads), seen through one DispatchSource on the folder: each finished one is reported
/// once. Browsers write to a temporary name (.crdownload, .download, .part) and rename it when done; Firefox also puts
/// an empty file at the final name while its .part is there, so a name with a .part beside it waits.
@MainActor final class FolderWatch {
    let dir: URL
    var onFile: ((URL) -> Void)?
    private var source: DispatchSourceFileSystemObject?
    private var known: Set<String> = []
    static let temporary: Set<String> = ["crdownload", "download", "part"]

    init(_ dir: URL) { self.dir = dir }

    func start() {
        known = names()
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        s.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.scan() } }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }

    private func names() -> Set<String> {
        let all = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        return all.filter { !$0.hasPrefix(".") && !Self.temporary.contains(($0 as NSString).pathExtension.lowercased()) && !all.contains($0 + ".part") }
    }

    private func scan() {
        let now = names()
        for name in now.subtracting(known).sorted() { onFile?(dir.appendingPathComponent(name)) }
        known = now
    }
}
