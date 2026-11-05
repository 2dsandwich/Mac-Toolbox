import CoreLocation
import Observation

/// Where the Mac is, roughly (a kilometre is plenty for weather and "near me"). The system asks for permission
/// only when something first needs it: the weather with no city set, Ask, or the button in Settings. The last fix
/// is kept for half an hour and named after its town.
@MainActor @Observable final class Location: NSObject, CLLocationManagerDelegate {
    static let shared = Location()

    struct Fix {
        var lat: Double
        var lon: Double
        var city: String?
        /// The neighbourhood (Shibuya, SoHo).
        var area: String?
        var region: String?
        var country: String?
        /// ISO 3166 ("JP").
        var countryCode: String?
        var zone: TimeZone?
        var at = Date()
        var name: String { city ?? area ?? region ?? "Current location" }
    }

    private(set) var fix: Fix?
    private(set) var status: CLAuthorizationStatus
    /// The last attempt failed and there's nothing older to fall back on.
    private(set) var failed = false

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var locating = false
    @ObservationIgnored private var waiting: [CheckedContinuation<Fix?, Never>] = []
    @ObservationIgnored private var listeners: [@MainActor () -> Void] = []
    /// Tests: a made-up place, and the real permission never asked.
    @ObservationIgnored private var fake = false

    override private init() {
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    var allowed: Bool { status == .authorizedAlways }
    var denied: Bool { status == .denied || status == .restricted }
    var undecided: Bool { status == .notDetermined }

    /// Called whenever the fix or the permission changes.
    func onChange(_ f: @escaping @MainActor () -> Void) { listeners.append(f) }

    /// Asks the system (once; after that only System Settings can change it).
    func requestPermission() {
        guard !fake, undecided else { return }
        manager.requestWhenInUseAuthorization()
    }

    /// A new fix when the last one is older than `maxAge`. Never asks for permission.
    func refresh(maxAge: TimeInterval = 1800) {
        guard !fake, allowed, !locating, Date().timeIntervalSince(fix?.at ?? .distantPast) > maxAge else { return }
        locating = true
        manager.requestLocation()
    }

    /// Where the Mac is now, asking for permission if it never has; nil when Location is off or it takes too long.
    func current(maxAge: TimeInterval = 1800, timeout: TimeInterval = 10) async -> Fix? {
        if let fix, fake || Date().timeIntervalSince(fix.at) < maxAge { return fix }
        if fake || denied { return fix }
        if undecided { requestPermission() } else { refresh(maxAge: maxAge) }
        return await withCheckedContinuation { c in
            waiting.append(c)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { MainActor.assumeIsolated { self.answer() } }
        }
    }

    /// Tests and snapshots: a made-up fix.
    func useFake(_ f: Fix) {
        fake = true
        status = .authorizedAlways
        fix = f
        changed()
    }

    private func answer() {
        let w = waiting
        waiting = []
        w.forEach { $0.resume(returning: fix) }
    }

    private func changed() { listeners.forEach { $0() } }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = manager.authorizationStatus
        MainActor.assumeIsolated {
            guard !fake else { return }
            status = s
            if allowed {
                failed = false
                refresh(maxAge: 1800)
            } else if denied {
                answer()
            }
            changed()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        let lat = loc.coordinate.latitude, lon = loc.coordinate.longitude
        MainActor.assumeIsolated {
            guard !fake else { return }
            locating = false
            failed = false
            // Keep the old names while the new ones are looked up (it's usually the same town).
            var f = fix ?? Fix(lat: lat, lon: lon)
            f.lat = lat
            f.lon = lon
            f.at = Date()
            fix = f
            changed()
            CLGeocoder().reverseGeocodeLocation(loc) { marks, _ in
                let m = marks?.first
                let named = m.map { ($0.locality ?? $0.subAdministrativeArea, $0.subLocality, $0.administrativeArea, $0.country, $0.isoCountryCode, $0.timeZone) }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let me = Location.shared
                        if let named, var f = me.fix {
                            (f.city, f.area, f.region, f.country, f.countryCode, f.zone) = named
                            me.fix = f
                            me.changed()
                        }
                        me.answer()
                    }
                }
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            locating = false
            if fix == nil { failed = true }
            answer()
            changed()
        }
    }
}
