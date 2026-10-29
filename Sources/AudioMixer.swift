import AppKit
import AudioToolbox
import CoreAudio
import Observation

/// Per-app volume. macOS has no setting for it, so an app turned down is tapped (Core Audio process tap,
/// muted at the source) and played back through a private aggregate device at the chosen level.
@MainActor @Observable final class AudioMixer {
    static let shared = AudioMixer()

    struct App: Identifiable {
        let id: String // bundle id of the app (helpers are grouped under it)
        let name: String
        let icon: NSImage
        var processes: [AudioObjectID]
        var playing: Bool
    }

    var apps: [App] = []
    /// 0…1 per app id (missing = 1). Kept across launches, and applied as soon as the app makes sound.
    var volumes: [String: Float] = [:] { didSet { save() } }
    var muted: Set<String> = [] { didSet { save() } }
    var master: Float = 0.5
    var masterMuted = false
    var problem: String?

    @ObservationIgnored private var taps: [String: Tap] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var watchers = 0
    /// Keeps checking in the background while some app is turned down, so it applies when that app starts playing.
    @ObservationIgnored private var keeper: Timer?

    init() {
        let d = UserDefaults.standard
        guard Store.shared.settings.rememberAppVolumes else { return }
        if let v = d.dictionary(forKey: "mixerVolumes") as? [String: Double] { volumes = v.mapValues(Float.init) }
        muted = Set(d.stringArray(forKey: "mixerMuted") ?? [])
        keepApplying()
    }

    private func save() {
        guard Store.shared.settings.rememberAppVolumes else {
            UserDefaults.standard.removeObject(forKey: "mixerVolumes")
            UserDefaults.standard.removeObject(forKey: "mixerMuted")
            return
        }
        UserDefaults.standard.set(volumes.mapValues(Double.init), forKey: "mixerVolumes")
        UserDefaults.standard.set(Array(muted), forKey: "mixerMuted")
    }

    private func keepApplying() {
        let needed = !volumes.isEmpty || !muted.isEmpty
        if needed, keeper == nil {
            let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.timer == nil else { return } // the on-screen refresh covers it
                    self.refresh()
                }
            }
            t.tolerance = 0.5
            RunLoop.main.add(t, forMode: .common)
            keeper = t
        } else if !needed {
            keeper?.invalidate()
            keeper = nil
        }
    }

    // MARK: Watching (while the mixer is on screen)

    func startWatching() {
        watchers += 1
        refresh()
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopWatching() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        master = Self.outputVolume() ?? master
        masterMuted = Self.outputMuted()
        var byApp: [String: App] = [:]
        let own = Bundle.main.bundleIdentifier ?? ""
        let regular = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        for obj in Self.processObjects() {
            guard let bundle = Self.string(obj, kAudioProcessPropertyBundleID), !bundle.isEmpty, bundle != own else { continue }
            let pid: pid_t = Self.value(obj, kAudioProcessPropertyPID) ?? 0
            let running: UInt32 = Self.value(obj, kAudioProcessPropertyIsRunningOutput) ?? 0
            // Helpers ("com.google.Chrome.helper") belong to the app whose id they start with.
            let owner = NSRunningApplication(processIdentifier: pid).flatMap { $0.activationPolicy == .regular ? $0 : nil }
                ?? regular.first { bundle.hasPrefix(($0.bundleIdentifier ?? "\u{0}") + ".") }
            guard let app = owner, let id = app.bundleIdentifier else { continue }
            if var a = byApp[id] {
                a.processes.append(obj)
                a.playing = a.playing || running != 0
                byApp[id] = a
            } else {
                byApp[id] = App(id: id, name: app.localizedName ?? id, icon: app.icon ?? NSImage(), processes: [obj], playing: running != 0)
            }
        }
        // Every open app, even quiet ones: a level set now applies once it makes sound.
        for app in regular {
            guard let id = app.bundleIdentifier, id != own, byApp[id] == nil else { continue }
            byApp[id] = App(id: id, name: app.localizedName ?? id, icon: app.icon ?? NSImage(), processes: [], playing: false)
        }
        func rank(_ a: App) -> Int { a.playing ? 0 : (volumes[a.id] != nil || muted.contains(a.id)) ? 1 : 2 }
        apps = byApp.values.sorted { (rank($0), $0.name.lowercased()) < (rank($1), $1.name.lowercased()) }
        for a in apps where !a.processes.isEmpty {
            let wanted = muted.contains(a.id) || volume(a.id) < 0.999
            // A new helper joined, or the sound now goes elsewhere (AirPods connected): the tap is made again.
            let output = Self.defaultOutput.flatMap { Self.string($0, kAudioDevicePropertyDeviceUID) }
            let stale = taps[a.id].map { Set($0.processes) != Set(a.processes) || $0.outputUID != output } ?? false
            if stale { taps.removeValue(forKey: a.id)?.stop() }
            if (wanted && taps[a.id] == nil) || stale { apply(a.id) } // started making sound, or needs making again
        }
    }

    // MARK: Changing

    func volume(_ id: String) -> Float { volumes[id] ?? 1 }

    func setVolume(_ v: Float, for id: String) {
        volumes[id] = min(1, max(0, v))
        apply(id)
        keepApplying()
    }

    func toggleMute(_ id: String) {
        if muted.contains(id) { muted.remove(id) } else { muted.insert(id) }
        apply(id)
        keepApplying()
    }

    func setMaster(_ v: Float) {
        master = min(1, max(0, v))
        Self.setOutputVolume(master)
        if master > 0, masterMuted { setMasterMuted(false) }
    }

    func setMasterMuted(_ on: Bool) {
        masterMuted = on
        Self.setOutputMuted(on)
    }

    private func apply(_ id: String) {
        let gain = muted.contains(id) ? 0 : volume(id)
        guard let app = apps.first(where: { $0.id == id }) else { return }
        if gain >= 0.999 {
            taps.removeValue(forKey: id)?.stop()
            if volumes[id] != nil { volumes[id] = nil }
            return
        }
        // Not making sound yet: nothing to tap. The level is saved and applied when it starts.
        guard !app.processes.isEmpty else { return }
        if let t = taps[id], Set(t.processes) == Set(app.processes) {
            t.gain.value = gain
            return
        }
        taps.removeValue(forKey: id)?.stop()
        do {
            let t = try Tap(processes: app.processes, gain: gain, name: app.name)
            taps[id] = t
            problem = nil
        } catch {
            problem = "Couldn’t change \(app.name)’s volume: \(error.localizedDescription). Allow MONEY! under System Settings › Privacy & Security › Screen & System Audio Recording."
        }
    }

    // MARK: Core Audio helpers

    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private static func processObjects() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func value<T>(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var addr = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        let p = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { p.deallocate() }
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, p) == noErr else { return nil }
        return p.pointee
    }

    static func string(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cf: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &cf) == noErr, let s = cf?.takeRetainedValue() else { return nil }
        return s as String
    }

    static var defaultOutput: AudioObjectID? {
        let id: AudioObjectID? = value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
        return id == 0 ? nil : id
    }

    static func outputVolume() -> Float? {
        guard let dev = defaultOutput else { return nil }
        return value(dev, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
    }

    static func setOutputVolume(_ v: Float) {
        guard let dev = defaultOutput else { return }
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
        var value = v
        AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float>.size), &value)
    }

    static func outputMuted(_ device: AudioObjectID? = nil) -> Bool {
        guard let dev = device ?? defaultOutput else { return false }
        let m: UInt32? = value(dev, kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        return (m ?? 0) != 0
    }

    /// Mutes the speakers (or `device`, the ones that were muted before, even if others are in use now).
    static func setOutputMuted(_ on: Bool, device: AudioObjectID? = nil) {
        guard let dev = device ?? defaultOutput else { return }
        var addr = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        var value: UInt32 = on ? 1 : 0
        AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }
}

/// The level read by the audio thread.
final class Gain: @unchecked Sendable {
    var value: Float
    init(_ v: Float) { value = v }
}

/// One app's tap: its sound muted at the source and replayed at `gain` on the current output.
@MainActor private final class Tap {
    let processes: [AudioObjectID]
    /// The speakers it plays to.
    private(set) var outputUID: String?
    let gain: Gain
    private var tapID = AudioObjectID(0)
    private var aggregateID = AudioObjectID(0)
    private var procID: AudioDeviceIOProcID?

    struct Failure: LocalizedError {
        let step: String
        let status: OSStatus
        var errorDescription: String? { "\(step) failed (\(status))" }
    }

    init(processes: [AudioObjectID], gain: Float, name: String) throws {
        self.processes = processes
        self.gain = Gain(gain)
        let desc = CATapDescription(stereoMixdownOfProcesses: processes)
        desc.uuid = UUID()
        desc.muteBehavior = .mutedWhenTapped
        desc.isPrivate = true
        desc.name = "MONEY! \(name)"
        var tap = AudioObjectID(0)
        var status = AudioHardwareCreateProcessTap(desc, &tap)
        guard status == noErr else { throw Failure(step: "Tapping the app", status: status) }
        tapID = tap
        guard let output = AudioMixer.defaultOutput, let outputUID = AudioMixer.string(output, kAudioDevicePropertyDeviceUID) else {
            stop()
            throw Failure(step: "Finding the speakers", status: -1)
        }
        self.outputUID = outputUID
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MONEY! Mixer",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        var agg = AudioObjectID(0)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg)
        guard status == noErr else {
            stop()
            throw Failure(step: "Making the playback device", status: status)
        }
        aggregateID = agg
        let level = self.gain
        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, DispatchQueue(label: "money.mixer", qos: .userInteractive)) { _, input, _, output, _ in
            let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            let outs = UnsafeMutableAudioBufferListPointer(output)
            let g = level.value
            for i in 0..<outs.count {
                guard let dst = outs[i].mData else { continue }
                let bytes = Int(outs[i].mDataByteSize)
                guard i < ins.count, let src = ins[i].mData else {
                    memset(dst, 0, bytes)
                    continue
                }
                let n = min(bytes, Int(ins[i].mDataByteSize)) / MemoryLayout<Float>.size
                let s = src.assumingMemoryBound(to: Float.self), d = dst.assumingMemoryBound(to: Float.self)
                for k in 0..<n { d[k] = s[k] * g }
                if n * 4 < bytes { memset(dst + n * 4, 0, bytes - n * 4) }
            }
        }
        guard status == noErr, let proc else {
            stop()
            throw Failure(step: "Starting playback", status: status)
        }
        procID = proc
        status = AudioDeviceStart(agg, proc)
        guard status == noErr else {
            stop()
            throw Failure(step: "Starting playback", status: status)
        }
    }

    func stop() {
        if aggregateID != 0, let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = 0
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID) }
        tapID = 0
    }
}
