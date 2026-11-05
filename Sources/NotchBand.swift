import AppKit
@preconcurrency import AVFoundation
import CoreAudio
import CoreLocation
import CoreMediaIO
import CoreWLAN
import IOKit.ps
import Observation
import SwiftUI

// What the open notch adds beside the hardware notch and behind its camera button: glances (the battery and others from
// Settings), and a mirror from the front camera. The camera runs only while the mirror shows.

/// The battery as iPhone shows it with its percentage: the number inside the battery, cut out of it, over the level;
/// green while charging (a bolt beside it), a plug beside it when plugged in but not charging, red when low on
/// battery, yellow in Low Power Mode. Nothing on Macs without one.
struct BatteryGlance: View {
    /// `--battery-states`: drawn for a made-up state.
    var fixed: Battery.State?

    var body: some View {
        if let b = fixed ?? Battery.shared.state {
            HStack(spacing: 3) {
                Self.icon(b)
                if b.charging || b.plugged {
                    Image(systemName: b.charging ? "bolt.fill" : "powerplug.fill").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .fixedSize()
            .help(b.detail)
        }
    }

    /// The battery body filled to its level, the percentage knocked out of it so it reads over either part.
    static func icon(_ b: Battery.State) -> some View {
        let w: CGFloat = 27, h: CGFloat = 13
        let color: Color = b.lowPower ? .yellow : b.low ? .red : b.charging ? .green : .white
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        return HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                shape.fill(Color.white.opacity(0.35))
                Rectangle().fill(color).frame(width: w * CGFloat(min(100, max(0, b.pct))) / 100)
                // Cut out of the battery: on the black notch, that's black.
                Text("\(b.pct)").font(.system(size: b.pct >= 100 ? 9 : 10, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.black)
                    .frame(width: w, height: h)
            }
            .frame(width: w, height: h)
            .clipShape(shape)
            Capsule().fill(Color.white.opacity(0.35)).frame(width: 1.5, height: 4.5)
        }
    }
}

/// The internal battery, read when the power source changes (IOKit tells us) or Low Power Mode is switched, never polled.
@MainActor @Observable final class Battery {
    static let shared = Battery()
    struct State: Equatable {
        var pct: Int
        var charging = false
        /// On the adapter (charging or not).
        var plugged = false
        var lowPower = false
        var charged = false
        /// Minutes to full or to empty (nil while macOS is still working it out).
        var minutes: Int?
        /// Low on battery: 20% or less, not plugged in.
        var low: Bool { pct <= 20 && !plugged }
        var detail: String {
            let time = minutes.map { $0 >= 60 ? "\($0 / 60) h \($0 % 60) min" : "\($0) min" }
            if charging { return time.map { "Charging, full in \($0)" } ?? "Charging" }
            if plugged { return charged ? "Fully charged" : "Plugged in, not charging" }
            return (time.map { "\($0) left" } ?? "On battery") + (lowPower ? ", Low Power Mode" : "")
        }
    }
    private(set) var state: State?
    @ObservationIgnored private var source: CFRunLoopSource?

    private init() {
        read()
        let source = IOPSNotificationCreateRunLoopSource({ _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { Battery.shared.read() } }
        }, nil)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode) }
        self.source = source
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Battery.shared.read() }
        }
    }

    func read() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { state = nil; return }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            let mins = d[charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? Int
            state = State(pct: Int((Double(cur) / Double(max) * 100).rounded()), charging: charging,
                          plugged: d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                          lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, charged: d[kIOPSIsChargedKey] as? Bool ?? false, minutes: mins.flatMap { $0 > 0 ? $0 : nil })
            return
        }
        state = nil
    }
}

/// One glance left of the notch (Settings › Notch picks one or two).
struct BandGlance: View {
    let item: BandItem

    var body: some View {
        let data = BandData.shared
        Group {
            switch item {
            case .battery: BatteryGlance()
            case .time: TimelineView(.everyMinute) { ctx in Text(ctx.date, format: .dateTime.hour().minute()).font(Self.font) }
            case .date:
                TimelineView(.everyMinute) { ctx in
                    label("calendar", Text(ctx.date, format: .dateTime.weekday(.abbreviated).day()))
                }
            case .weather:
                if let w = data.weather { label(w.symbol, Text("\(w.temp)°")) } else { label("cloud", Text("")).opacity(0.4) }
            case .event:
                if let e = BandData.nextToday {
                    HStack(spacing: 6) {
                        Circle().fill(Color(nsColor: e.color)).frame(width: 7, height: 7)
                        Text(e.start > CalendarEvents.shared.now ? e.countdown(CalendarEvents.shared.now) : "Now").font(Self.font)
                    }
                } else {
                    label("calendar", Text("")).opacity(0.4)
                }
            case .cpu: label("cpu", Text("\(Int((data.cpu * 100).rounded()))%"))
            case .memory: label("memorychip", Text("\(Int((data.memory * 100).rounded()))%"))
            case .network:
                VStack(alignment: .leading, spacing: 0) {
                    Text("↑ " + Self.rate(data.up))
                    Text("↓ " + Self.rate(data.down))
                }
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
            case .wifi: label(data.wifi == nil ? "wifi.slash" : "wifi", Text(data.wifi ?? ""))
            case .privacy:
                HStack(spacing: 6) {
                    Image(systemName: "mic.fill").foregroundStyle(data.micInUse ? Color.orange : Color.white.opacity(0.3))
                    Image(systemName: "video.fill").foregroundStyle(data.cameraInUse ? Color.green : Color.white.opacity(0.3))
                }
                .font(.system(size: 12, weight: .medium))
            case .disk: label("internaldrive", Text("\(data.freeDisk / 1_000_000_000) GB"))
            }
        }
        .foregroundStyle(.white.opacity(0.85))
        .lineLimit(1)
        .frame(maxWidth: item.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { data.watch(item, true) }
        .onDisappear { data.watch(item, false) }
    }

    static let font = Font.system(size: 12, weight: .semibold).monospacedDigit()

    private func label(_ symbol: String, _ text: Text) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
            text.font(Self.font)
        }
    }

    /// Bytes a second, short: "0K", "850K", "1.2M", "12M".
    static func rate(_ b: Double) -> String {
        let k = b / 1024
        if k < 1000 { return "\(Int(k.rounded()))K" }
        let m = k / 1024
        return m < 10 ? String(format: "%.1fM", m) : "\(Int(m.rounded()))M"
    }
}

/// The numbers behind the glances, sampled only while one that shows them is on screen (every two seconds; Wi-Fi every
/// ten, the disk every minute, the weather every ten minutes).
@MainActor @Observable final class BandData {
    static let shared = BandData()
    private(set) var cpu = 0.0
    private(set) var memory = 0.0
    private(set) var up = 0.0
    private(set) var down = 0.0
    private(set) var wifi: String?
    private(set) var micInUse = false
    private(set) var cameraInUse = false
    private(set) var freeDisk: Int64 = 0
    var weather: (symbol: String, temp: Int, hi: Int, lo: Int)?
    @ObservationIgnored private var watching: [BandItem: Int] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var tick = 0
    @ObservationIgnored private var cpuTicks: [UInt32] = []
    @ObservationIgnored private var bytes: (up: UInt64, down: UInt64, at: Date)?
    @ObservationIgnored private var weatherAt = Date.distantPast

    /// The rest of today's next event (not all-day), for the band and the idle notch.
    static var nextToday: CalendarEvent? {
        let c = CalendarEvents.shared
        return c.events.first { $0.end > c.now && !$0.allDay && Calendar.current.isDate($0.start, inSameDayAs: c.now) }
    }

    func watch(_ item: BandItem, _ on: Bool) {
        watching[item, default: 0] += on ? 1 : -1
        guard watching.values.contains(where: { $0 > 0 }) else {
            timer?.invalidate()
            timer = nil
            return
        }
        if on { sample(item, first: true) }
        guard timer == nil else { return }
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tick += 1
                for (item, n) in self.watching where n > 0 { self.sample(item, first: false) }
            }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func sample(_ item: BandItem, first: Bool) {
        switch item {
        case .cpu: cpu = cpuLoad() ?? cpu
        case .memory: memory = memoryUsed() ?? memory
        case .network: network()
        case .privacy:
            micInUse = Self.micRunning()
            cameraInUse = Self.cameraRunning()
        case .wifi where first || tick % 5 == 0: wifi = CWWiFiClient.shared().interface()?.ssid()
        case .disk where first || tick % 30 == 0:
            freeDisk = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage ?? 0
        case .weather: loadWeather()
        default: break
        }
    }

    /// From the search bar's weather (Open-Meteo, cached ten minutes), for the city in Settings or, once Location is
    /// allowed, where you are; never asks for Location itself.
    func loadWeather() {
        guard weather == nil || Date().timeIntervalSince(weatherAt) > 600 else { return }
        let s = Store.shared.settings
        let status = Self.locator.authorizationStatus
        guard !s.weatherCity.trimmingCharacters(in: .whitespaces).isEmpty || status == .authorizedAlways else { return }
        guard case .weather(let f, _)? = LiveData.shared.weather(place: "", kind: .full, s).first?.card else { return }
        weatherAt = Date()
        weather = (Self.symbol(f.code, day: f.isDay), Int(f.temp.rounded()), Int((f.days.first?.hi ?? f.temp).rounded()), Int((f.days.first?.lo ?? f.temp).rounded()))
    }
    private static let locator = CLLocationManager()

    /// An SF Symbol for a WMO weather code.
    static func symbol(_ c: Int, day: Bool) -> String {
        switch c {
        case 0, 1: day ? "sun.max.fill" : "moon.stars.fill"
        case 2: day ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51...57: "cloud.drizzle.fill"
        case 61...67, 80...82: "cloud.rain.fill"
        case 71...77, 85, 86: "cloud.snow.fill"
        case 95...99: "cloud.bolt.rain.fill"
        default: "thermometer.medium"
        }
    }

    private func cpuLoad() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard ok == KERN_SUCCESS else { return nil }
        let now = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3] // user, system, idle, nice
        defer { cpuTicks = now }
        // The first look has nothing to compare with: the average since the Mac started, until the next one.
        let d = cpuTicks.count == 4 ? zip(now, cpuTicks).map { Double($0 &- $1) } : now.map(Double.init)
        let total = d.reduce(0, +)
        return total > 0 ? (total - d[2]) / total : nil
    }

    private func memoryUsed() -> Double? {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard ok == KERN_SUCCESS else { return nil }
        // As Activity Monitor counts "Memory Used": app memory, wired and compressed.
        let pages = Double(vm.internal_page_count) - Double(vm.purgeable_count) + Double(vm.wire_count) + Double(vm.compressor_page_count)
        return min(1, pages * Double(vm_kernel_page_size) / Double(ProcessInfo.processInfo.physicalMemory))
    }

    private func network() {
        var up: UInt64 = 0, down: UInt64 = 0
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return }
        defer { freeifaddrs(list) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let a = p.pointee
            guard a.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), !String(cString: a.ifa_name).hasPrefix("lo"),
                  let data = a.ifa_data?.assumingMemoryBound(to: if_data.self).pointee else { continue }
            up += UInt64(data.ifi_obytes)
            down += UInt64(data.ifi_ibytes)
        }
        let now = Date()
        if let b = bytes {
            let dt = max(0.5, now.timeIntervalSince(b.at))
            self.up = Double(up >= b.up ? up - b.up : 0) / dt
            self.down = Double(down >= b.down ? down - b.down : 0) / dt
        }
        bytes = (up, down, now)
    }

    /// Something is recording from the default microphone.
    private static func micRunning() -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var dev = AudioObjectID(0), size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr else { return false }
        var on: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        addr.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &on) == noErr && on != 0
    }

    /// Some app has a camera on.
    private static func cameraRunning() -> Bool {
        var addr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                             mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                             mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0, used: UInt32 = 0
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == 0 else { return false }
        var ids = [CMIODeviceID](repeating: 0, count: Int(size) / MemoryLayout<CMIODeviceID>.size)
        guard CMIOObjectGetPropertyData(system, &addr, 0, nil, size, &used, &ids) == 0 else { return false }
        addr.mSelector = CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere)
        return ids.contains { id in
            var on: UInt32 = 0, got: UInt32 = 0
            return CMIOObjectGetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &got, &on) == 0 && on != 0
        }
    }
}

/// The front camera for the open notch's mirror.
@MainActor @Observable final class CameraMirror {
    static let shared = CameraMirror()
    enum State { case off, running, denied }
    private(set) var state = State.off
    /// `--island-snapshot`: a stand-in picture, and the real camera is never touched (its light would come on).
    @ObservationIgnored static var placeholder = false
    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private let queue = DispatchQueue(label: "MONEY.camera")
    @ObservationIgnored private var wanted = false
    @ObservationIgnored private var configured = false

    /// The built-in camera, else whatever macOS picks.
    private static let device: AVCaptureDevice? = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified).devices.first
        ?? AVCaptureDevice.default(for: .video)
    /// Whether there's a camera for the button to open.
    static var available: Bool { placeholder || device != nil }

    /// The mirror showed: start (asking for access the first time).
    func start() {
        guard !Self.placeholder, !wanted else { return }
        wanted = true
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: run()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                Task { @MainActor in
                    let m = CameraMirror.shared
                    if !ok { m.state = .denied } else if m.wanted { m.run() }
                }
            }
        default: state = .denied
        }
    }

    private func run() {
        if !configured, let d = Self.device, let input = try? AVCaptureDeviceInput(device: d), session.canAddInput(input) {
            session.beginConfiguration()
            session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high
            session.addInput(input)
            session.commitConfiguration()
            configured = true
        }
        guard configured else { state = .denied; return }
        state = .running
        let s = session
        queue.async { if !s.isRunning { s.startRunning() } }
    }

    /// The mirror went away (or the notch closed): the camera goes off at once.
    func stop() {
        guard wanted else { return }
        wanted = false
        if state == .running { state = .off }
        let s = session
        queue.async { if s.isRunning { s.stopRunning() } }
    }
}

/// The mirror: the front camera, flipped like a mirror and cropped to fill.
struct CameraView: View {
    var body: some View {
        let mirror = CameraMirror.shared
        ZStack {
            Color.white.opacity(0.07)
            if CameraMirror.placeholder {
                // A stand-in frame for snapshots.
                LinearGradient(colors: [Color(red: 0.32, green: 0.27, blue: 0.24), Color(red: 0.12, green: 0.11, blue: 0.12)], startPoint: .top, endPoint: .bottom)
                Image(systemName: "person.fill").font(.system(size: 120)).foregroundStyle(.white.opacity(0.22)).offset(y: 34)
            } else if mirror.state == .denied {
                Image(systemName: "video.slash.fill").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
            } else {
                PreviewLayer(session: mirror.session, state: mirror.state)
            }
        }
        .onAppear { mirror.start() }
        .onDisappear { mirror.stop() }
    }
}

private struct PreviewLayer: NSViewRepresentable {
    let session: AVCaptureSession
    let state: CameraMirror.State

    func makeNSView(context: Context) -> PreviewView { PreviewView(session: session) }
    func updateNSView(_ view: PreviewView, context: Context) { view.mirror() }

    final class PreviewView: NSView {
        private let preview: AVCaptureVideoPreviewLayer

        init(session: AVCaptureSession) {
            preview = AVCaptureVideoPreviewLayer(session: session)
            super.init(frame: .zero)
            wantsLayer = true
            preview.videoGravity = .resizeAspectFill
            layer?.addSublayer(preview)
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            preview.frame = bounds
            CATransaction.commit()
            mirror()
        }

        /// Flipped left to right, like a mirror (once the camera is connected).
        func mirror() {
            guard let c = preview.connection, c.isVideoMirroringSupported, !c.isVideoMirrored else { return }
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = true
        }
    }
}
