import AppKit
@preconcurrency import AVFoundation
import IOKit.ps
import Observation
import SwiftUI

// What the open notch adds beside the hardware notch and behind its camera button: the battery, and a mirror from the
// front camera. The camera runs only while the mirror shows.

/// The battery beside the notch: its level and whether it's charging, read once a minute. Nothing on Macs without one.
struct BatteryGlance: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            if let b = Self.read() {
                let level = b.pct > 87 ? "100" : b.pct > 62 ? "75" : b.pct > 37 ? "50" : b.pct > 12 ? "25" : "0"
                HStack(spacing: 5) {
                    // Only the full battery has a charging version of the symbol.
                    Image(systemName: b.charging ? "battery.100percent.bolt" : "battery.\(level)percent")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(b.pct <= 20 && !b.plugged ? Color.red : b.charging ? Color.green : Color.white.opacity(0.85))
                    Text("\(b.pct)%").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.white.opacity(0.85))
                }
                .fixedSize()
            }
        }
    }

    static func read() -> (pct: Int, charging: Bool, plugged: Bool)? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  d["Type"] as? String == "InternalBattery",
                  let cur = d["Current Capacity"] as? Int, let max = d["Max Capacity"] as? Int, max > 0 else { continue }
            return (Int((Double(cur) / Double(max) * 100).rounded()), d["Is Charging"] as? Bool ?? false, d["Power Source State"] as? String == "AC Power")
        }
        return nil
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
