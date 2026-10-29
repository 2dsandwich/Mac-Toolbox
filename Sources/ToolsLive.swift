import AppKit
import CoreLocation
import IOKit.ps
import IOKit.pwr_mgt

/// Answers that need the network (weather, exchange rates, holidays, public IP, translation).
/// Results are cached; when one arrives the launcher redraws its answers.
@MainActor final class LiveData: NSObject, CLLocationManagerDelegate {
    static let shared = LiveData()
    var onUpdate: (() -> Void)?

    private var cache: [String: (value: Any, time: Date)] = [:]
    private var failed: [String: (message: String, time: Date)] = [:]
    private var loading = Set<String>()
    /// One waiting request per kind, so typing "weather t…o…k…" only looks up the last one.
    private var pending: [String: (key: String, item: DispatchWorkItem)] = [:]

    private func cached<T>(_ key: String, _ maxAge: TimeInterval = .infinity) -> T? {
        guard let e = cache[key], Date().timeIntervalSince(e.time) < maxAge else { return nil }
        return e.value as? T
    }

    private func age(_ key: String) -> TimeInterval { cache[key].map { Date().timeIntervalSince($0.time) } ?? .infinity }

    private func failure(_ key: String) -> String? {
        guard let f = failed[key], Date().timeIntervalSince(f.time) < 60 else { return nil }
        return f.message
    }

    private func load(_ key: String, kind: String, delay: Double = 0.35, _ work: @escaping @MainActor () async throws -> Any) {
        guard !loading.contains(key) else { return }
        if let p = pending[kind] {
            p.item.cancel()
            loading.remove(p.key)
        }
        loading.insert(key)
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.pending[kind]?.key == key { self.pending[kind] = nil }
                Task { @MainActor in
                    do {
                        self.cache[key] = (try await work(), Date())
                        self.failed[key] = nil
                    } catch {
                        self.failed[key] = (error.localizedDescription, Date())
                    }
                    self.loading.remove(key)
                    self.onUpdate?()
                }
            }
        }
        pending[kind] = (key, item)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private static func json(_ url: String) async throws -> Any {
        guard let u = URL(string: url) else { throw URLError(.badURL) }
        var req = URLRequest(url: u, timeoutInterval: 10)
        req.setValue("MONEY!/1.0 (macOS launcher)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONSerialization.jsonObject(with: data)
    }

    private func loadingRow(_ title: String, _ symbol: String = "arrow.triangle.2.circlepath", _ color: NSColor = .systemGray) -> Answer {
        Answer(title: title, subtitle: "", symbol: symbol, color: color)
    }

    private func errorRow(_ title: String, _ detail: String, _ symbol: String = "exclamationmark.triangle.fill") -> Answer {
        Answer(title: title, subtitle: detail, symbol: symbol, color: .systemOrange)
    }

    // MARK: Weather (Open-Meteo, no key needed)

    enum WeatherKind { case full, rain, sun }

    struct Place {
        let name: String
        let lat: Double
        let lon: Double
    }

    struct Forecast {
        struct Day { let date: Date; let code: Int; let hi: Double; let lo: Double; let rain: Int; let sunrise: Date?; let sunset: Date?; let uv: Double }
        struct Hour { let time: Date; let temp: Double; let rain: Int; let code: Int }
        var temp = 0.0, feels = 0.0, wind = 0.0
        var humidity = 0, code = 0
        var isDay = true
        var days: [Day] = []
        var hours: [Hour] = []
        var zone = TimeZone.current
        var windUnit = "km/h"
    }

    func weather(place raw: String, kind: WeatherKind, _ s: Settings) -> [Answer] {
        var query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { query = s.weatherCity.trimmingCharacters(in: .whitespaces) }
        let place: Place
        if query.isEmpty {
            guard let here = currentPlace() else { return [locationRow()] }
            place = here
        } else {
            let key = "geo:" + query.lowercased()
            if let p: Place = cached(key) {
                place = p
            } else if let err = failure(key) {
                return [errorRow("Couldn’t find “\(query)”", err, "mappin.slash")]
            } else {
                load(key, kind: "geo") { try await Self.geocode(query) }
                return [loadingRow("Looking up \(query)…", "location.magnifyingglass", .systemBlue)]
            }
        }
        let key = String(format: "wx:%.2f,%.2f,%@", place.lat, place.lon, s.fahrenheit ? "f" : "c")
        let fahrenheit = s.fahrenheit
        if age(key) > 600 { load(key, kind: "wx", delay: 0) { try await Self.forecast(place, fahrenheit: fahrenheit) } }
        if let f: Forecast = cached(key) { return weatherRows(f, place, kind) }
        if let err = failure(key) { return [errorRow("Weather is unavailable", err)] }
        return [loadingRow(place.name, "cloud.sun.fill", .systemBlue)]
    }

    private static func geocode(_ q: String) async throws -> Place {
        var name = q.components(separatedBy: CharacterSet(charactersIn: ",、")).first ?? q
        let cjk = name.unicodeScalars.contains { (0x3040...0x9FFF).contains($0.value) }
        if cjk {
            // Open-Meteo only knows Latin names: 大阪 → osaka.
            for suffix in ["市", "都", "府", "県", "区", "町", "村"] where name.count > 2 && name.hasSuffix(suffix) { name.removeLast() }
            name = Tools.romaji(name).folding(options: .diacriticInsensitive, locale: nil).replacingOccurrences(of: " ", with: "")
            // Long vowels the way place names are written in English: oosaka → osaka, toukyou → tokyo.
            for (long, short) in [("ou", "o"), ("oo", "o"), ("uu", "u")] { name = name.replacingOccurrences(of: long, with: short) }
        }
        let enc = name.addingPercentEncoding(withAllowedCharacters: .queryValue) ?? name
        let obj = try await json("https://geocoding-api.open-meteo.com/v1/search?name=\(enc)&count=1&format=json&language=\(cjk ? "ja" : "en")")
        guard let r = ((obj as? [String: Any])?["results"] as? [[String: Any]])?.first,
              let lat = r["latitude"] as? Double, let lon = r["longitude"] as? Double else {
            throw NSError(domain: "MONEY", code: 1, userInfo: [NSLocalizedDescriptionKey: "No place by that name"])
        }
        let title = [r["name"] as? String, r["country_code"] as? String].compactMap { $0 }.joined(separator: ", ")
        return Place(name: title, lat: lat, lon: lon)
    }

    private static func forecast(_ p: Place, fahrenheit: Bool) async throws -> Forecast {
        var url = "https://api.open-meteo.com/v1/forecast?latitude=\(p.lat)&longitude=\(p.lon)"
            + "&current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,is_day"
            + "&hourly=temperature_2m,precipitation_probability,weather_code"
            + "&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset,uv_index_max"
            + "&timezone=auto&forecast_days=7"
        if fahrenheit { url += "&temperature_unit=fahrenheit&wind_speed_unit=mph" }
        guard let o = try await json(url) as? [String: Any] else { throw URLError(.cannotParseResponse) }
        var f = Forecast()
        let offset = o["utc_offset_seconds"] as? Int ?? 0
        f.zone = TimeZone(secondsFromGMT: offset) ?? .current
        f.windUnit = fahrenheit ? "mph" : "km/h"
        let c = o["current"] as? [String: Any] ?? [:]
        f.temp = c["temperature_2m"] as? Double ?? 0
        f.feels = c["apparent_temperature"] as? Double ?? f.temp
        f.humidity = (c["relative_humidity_2m"] as? NSNumber)?.intValue ?? 0
        f.code = (c["weather_code"] as? NSNumber)?.intValue ?? 0
        f.wind = c["wind_speed_10m"] as? Double ?? 0
        f.isDay = (c["is_day"] as? NSNumber)?.intValue != 0
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = f.zone
        df.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let dayF = DateFormatter()
        dayF.locale = Locale(identifier: "en_US_POSIX")
        dayF.timeZone = f.zone
        dayF.dateFormat = "yyyy-MM-dd"
        func nums(_ d: [String: Any], _ k: String) -> [Double] { (d[k] as? [Any] ?? []).map { ($0 as? NSNumber)?.doubleValue ?? 0 } }
        func strs(_ d: [String: Any], _ k: String) -> [String] { d[k] as? [String] ?? [] }
        let d = o["daily"] as? [String: Any] ?? [:]
        let times = strs(d, "time"), codes = nums(d, "weather_code"), hi = nums(d, "temperature_2m_max"), lo = nums(d, "temperature_2m_min")
        let rain = nums(d, "precipitation_probability_max"), rise = strs(d, "sunrise"), set = strs(d, "sunset"), uv = nums(d, "uv_index_max")
        for i in times.indices {
            guard let date = dayF.date(from: times[i]) else { continue }
            f.days.append(.init(date: date, code: Int(codes[safe: i] ?? 0), hi: hi[safe: i] ?? 0, lo: lo[safe: i] ?? 0, rain: Int(rain[safe: i] ?? 0),
                                sunrise: rise[safe: i].flatMap(df.date), sunset: set[safe: i].flatMap(df.date), uv: uv[safe: i] ?? 0))
        }
        let h = o["hourly"] as? [String: Any] ?? [:]
        let hTimes = strs(h, "time"), hTemp = nums(h, "temperature_2m"), hRain = nums(h, "precipitation_probability"), hCode = nums(h, "weather_code")
        let now = Date().addingTimeInterval(-3600)
        for i in hTimes.indices {
            guard let t = df.date(from: hTimes[i]), t >= now else { continue }
            f.hours.append(.init(time: t, temp: hTemp[safe: i] ?? 0, rain: Int(hRain[safe: i] ?? 0), code: Int(hCode[safe: i] ?? 0)))
            if f.hours.count >= 25 { break }
        }
        return f
    }

    static func wmo(_ c: Int, day: Bool = true) -> (emoji: String, text: String) {
        switch c {
        case 0: (day ? "☀️" : "🌙", "Clear")
        case 1: (day ? "🌤️" : "🌙", "Mostly clear")
        case 2: ("⛅️", "Partly cloudy")
        case 3: ("☁️", "Cloudy")
        case 45, 48: ("🌫️", "Fog")
        case 51, 53, 55: ("🌦️", "Drizzle")
        case 56, 57: ("🌧️", "Freezing drizzle")
        case 61: ("🌧️", "Light rain")
        case 63: ("🌧️", "Rain")
        case 65: ("🌧️", "Heavy rain")
        case 66, 67: ("🌧️", "Freezing rain")
        case 71: ("🌨️", "Light snow")
        case 73: ("🌨️", "Snow")
        case 75: ("❄️", "Heavy snow")
        case 77: ("🌨️", "Snow grains")
        case 80, 81: ("🌦️", "Showers")
        case 82: ("⛈️", "Heavy showers")
        case 85, 86: ("🌨️", "Snow showers")
        case 95: ("⛈️", "Thunderstorm")
        case 96, 99: ("⛈️", "Thunderstorm with hail")
        default: ("🌡️", "Weather")
        }
    }

    private func weatherRows(_ f: Forecast, _ p: Place, _ kind: WeatherKind) -> [Answer] {
        let open = Answer.Action.open(URL(fileURLWithPath: "/System/Applications/Weather.app"))
        func deg(_ v: Double) -> String { "\(Int(v.rounded()))°" }
        let clock = DateFormatter()
        clock.timeZone = f.zone
        clock.timeStyle = .short
        let today = f.days.first
        let next = f.hours.prefix(13)
        let rainSoon = next.map(\.rain).max() ?? 0

        func row(_ title: String, _ sub: String, _ emoji: String) -> Answer {
            Answer(title: title, subtitle: sub, emoji: emoji, action: open, hint: "Weather ↩")
        }

        switch kind {
        case .rain:
            let tomorrow = f.days.count > 1 ? f.days[1].rain : 0
            let need = max(rainSoon, today?.rain ?? 0) >= 50
            let verdict = need ? "☂️ Take an umbrella" : "🌂 No umbrella needed"
            var r = row(verdict, "\(p.name) · Rain chance \(today?.rain ?? 0)% today, \(tomorrow)% tomorrow", need ? "☂️" : "🌂")
            r.card = .rain(f, place: p.name, verdict: verdict)
            return [r]
        case .sun:
            guard let t = today, let rise = t.sunrise, let set = t.sunset else { return [] }
            let len = set.timeIntervalSince(rise)
            let daylight = "\(Int(len / 3600)) h \(Int(len.truncatingRemainder(dividingBy: 3600) / 60)) min of daylight"
            var r = row("Sunrise \(clock.string(from: rise)) · Sunset \(clock.string(from: set))", "\(p.name) · \(daylight)", "🌅")
            var chips: [ToolCard.Chip] = [.init(label: "Sunrise", value: clock.string(from: rise), action: .copy(clock.string(from: rise)))]
            if f.days.count > 1, let r2 = f.days[1].sunrise, let s2 = f.days[1].sunset {
                chips.append(.init(label: "Tomorrow", value: "\(clock.string(from: r2)) – \(clock.string(from: s2))", action: .copy("\(clock.string(from: r2)) – \(clock.string(from: s2))")))
            }
            r.card = .big(.init(title: "Sun · \(p.name)", symbol: "sunset.fill", color: .systemOrange, caption: "Sunset today", value: clock.string(from: set),
                                detail: "Sunrise \(clock.string(from: rise)) · \(daylight)", chips: chips))
            return [r]
        case .full:
            let now = Self.wmo(f.code, day: f.isDay)
            var r = row("\(deg(f.temp)) \(now.text)",
                        "\(p.name) · Feels like \(deg(f.feels))" + (today.map { " · H \(deg($0.hi)) L \(deg($0.lo))" } ?? "") + " · Humidity \(f.humidity)% · Wind \(Int(f.wind.rounded())) \(f.windUnit)",
                        now.emoji)
            r.card = .weather(f, place: p.name)
            return [r]
        }
    }

    // Current location (asked once; type a city or set one in Settings when it's off).

    private lazy var locator: CLLocationManager = {
        let m = CLLocationManager()
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyKilometer
        return m
    }()
    private var here: Place?
    private var hereTime = Date.distantPast
    private var locating = false
    private var locationOff = false

    private func currentPlace() -> Place? {
        if Date().timeIntervalSince(hereTime) > 1800 { requestLocation() }
        return here
    }

    private func requestLocation() {
        guard !locating else { return }
        switch locator.authorizationStatus {
        case .denied, .restricted:
            locationOff = true
        case .notDetermined:
            locating = true
            locator.requestWhenInUseAuthorization()
        default:
            locating = true
            locator.requestLocation()
        }
    }

    private func locationRow() -> Answer {
        if locationOff {
            return Answer(title: "Location is off for MONEY!", subtitle: "Settings › Tools", symbol: "location.slash.fill",
                          color: .systemBlue, action: .run(keepOpen: false) { Tools.openSettings() }, hint: "Settings ↩")
        }
        return loadingRow("Finding where you are…", "location.fill", .systemBlue)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            switch manager.authorizationStatus {
            case .notDetermined: break
            case .denied, .restricted:
                locating = false
                locationOff = true
                onUpdate?()
            default:
                locationOff = false
                locating = true
                manager.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        let lat = loc.coordinate.latitude, lon = loc.coordinate.longitude
        MainActor.assumeIsolated {
            locating = false
            hereTime = Date()
            here = Place(name: here?.name ?? "Current location", lat: lat, lon: lon)
            onUpdate?()
            CLGeocoder().reverseGeocodeLocation(loc) { [weak self] marks, _ in
                let name = marks?.first.flatMap { $0.locality ?? $0.subAdministrativeArea ?? $0.administrativeArea }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, let name else { return }
                        self.here = Place(name: name, lat: lat, lon: lon)
                        self.onUpdate?()
                    }
                }
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            locating = false
            if here == nil { locationOff = true }
            onUpdate?()
        }
    }

    // MARK: Exchange rates (ECB via Frankfurter) and crypto (CoinGecko)

    func convert(_ amount: Double, from: String, to targets: [String]) -> [Answer] {
        if age("fx") > 6 * 3600 { load("fx", kind: "fx", delay: 0) { try await Self.rates() } }
        let needCrypto = Tools.crypto[from] != nil || targets.contains { Tools.crypto[$0] != nil }
        if needCrypto, age("crypto") > 300 { load("crypto", kind: "crypto", delay: 0) { try await Self.cryptoRates() } }
        guard var rates: [String: Double] = cached("fx") else {
            if let err = failure("fx") { return [errorRow("Couldn’t get exchange rates", err)] }
            return [loadingRow("Getting exchange rates…", "yensign.circle.fill", .systemGreen)]
        }
        var source = "ECB rate" + ((cached("fxdate") as String?).map { ", \($0)" } ?? "")
        if needCrypto {
            guard let c: [String: Double] = cached("crypto") else {
                if let err = failure("crypto") { return [errorRow("Couldn’t get crypto prices", err)] }
                return [loadingRow("Getting crypto prices…", "bitcoinsign.circle.fill", .systemYellow)]
            }
            rates.merge(c) { a, _ in a }
            source = "CoinGecko"
        }
        guard let rf = rates[from], rf > 0, let main = targets.first, let rt = rates[main] else {
            return [errorRow("No rate for \(from) → \(targets.first ?? "")", source)]
        }
        let out = amount / rf * rt
        let one = 1 / rf * rt
        let digits = Tools.crypto[main] != nil ? 8 : 2
        let symbol = main == "JPY" ? "yensign.circle.fill" : main == "EUR" ? "eurosign.circle.fill" : main == "GBP" ? "sterlingsign.circle.fill"
            : Tools.crypto[main] != nil ? "bitcoinsign.circle.fill" : "dollarsign.circle.fill"
        var others = Array(targets.dropFirst())
        for c in ["USD", "EUR", "JPY", "GBP", "KRW", "CNY", "AUD"] where c != from && c != main && !others.contains(c) { others.append(c) }
        let chips: [ToolCard.Chip] = others.prefix(4).compactMap { code in
            guard let r = rates[code] else { return nil }
            let v = amount / rf * r
            return .init(label: code, value: Tools.moneyValue(v, code), action: .copy(Tools.plain(v, digits: Tools.crypto[code] != nil ? 8 : 2)))
        }
        return [Answer(title: Tools.money(out, main), subtitle: "\(Tools.money(amount, from)) · 1 \(from) = \(Tools.fmt(one, digits: one < 1 ? 6 : 2)) \(main) · \(source)",
                       symbol: symbol, color: .systemGreen, action: .copy(Tools.plain(out, digits: digits)),
                       card: .big(.init(title: "Currency · \(source)", symbol: symbol, color: .systemGreen, caption: "\(Tools.money(amount, from)) =",
                                        value: Tools.moneyValue(out, main), unit: main, detail: "1 \(from) = \(Tools.fmt(one, digits: one < 1 ? 6 : 2)) \(main)", chips: chips,
                                        controls: currencyControls(amount, from: from, to: main))))]
    }

    private func currencyControls(_ amount: Double, from: String, to: String) -> [ToolCard.Control] {
        let n = Tools.plain(amount, digits: 8)
        let codes = ["JPY", "USD", "EUR", "GBP", "KRW", "CNY", "TWD", "HKD", "SGD", "THB", "AUD", "CAD", "CHF", "INR", "BTC", "ETH"].filter { Tools.currencyCodes.contains($0) }
        return [
            .init(symbol: "banknote", title: from, help: "Convert from", menu: codes.filter { $0 != to }.map { ($0, .fill("\(n) \($0) to \(to)")) }),
            .init(symbol: "arrow.left.arrow.right", help: "Swap", action: .fill("\(n) \(to) to \(from)")),
            .init(symbol: "banknote.fill", title: to, help: "Convert to", menu: codes.filter { $0 != from }.map { ($0, .fill("\(n) \(from) to \($0)")) }),
        ]
    }

    private static func rates() async throws -> Any {
        guard let o = try await json("https://api.frankfurter.dev/v1/latest?base=USD") as? [String: Any],
              var r = (o["rates"] as? [String: Any])?.compactMapValues({ ($0 as? NSNumber)?.doubleValue }) else { throw URLError(.cannotParseResponse) }
        r["USD"] = 1
        if let date = o["date"] as? String {
            let inF = DateFormatter()
            inF.locale = Locale(identifier: "en_US_POSIX")
            inF.dateFormat = "yyyy-MM-dd"
            let outF = DateFormatter()
            outF.dateFormat = "MMM d"
            LiveData.shared.cache["fxdate"] = (inF.date(from: date).map(outF.string) ?? date, Date())
        }
        return r
    }

    private static func cryptoRates() async throws -> Any {
        let ids = Tools.crypto.values.joined(separator: ",")
        guard let o = try await json("https://api.coingecko.com/api/v3/simple/price?ids=\(ids)&vs_currencies=usd") as? [String: Any] else { throw URLError(.cannotParseResponse) }
        var r: [String: Double] = [:]
        for (code, id) in Tools.crypto {
            if let usd = ((o[id] as? [String: Any])?["usd"] as? NSNumber)?.doubleValue, usd > 0 { r[code] = 1 / usd }
        }
        return r
    }

    // MARK: Japanese holidays

    func holidays() -> [Answer] {
        if age("holidays") > 86_400 { load("holidays", kind: "holidays", delay: 0) { try await Self.fetchHolidays() } }
        guard let list: [(Date, String)] = cached("holidays") else {
            if let err = failure("holidays") { return [errorRow("Couldn’t get the holiday list", err)] }
            return [loadingRow("Getting Japanese holidays…", "flag.fill", .systemRed)]
        }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let df = DateFormatter()
        df.dateFormat = "EEE, MMM d, yyyy"
        let iso = DateFormatter()
        iso.locale = Locale(identifier: "en_US_POSIX")
        iso.dateFormat = "yyyy-MM-dd"
        return list.filter { $0.0 >= today }.prefix(6).map { d, name in
            let n = cal.dateComponents([.day], from: today, to: d).day ?? 0
            return Answer(title: name, subtitle: df.string(from: d) + " · " + (n == 0 ? "today" : n == 1 ? "tomorrow" : "in \(n) days"),
                          symbol: "flag.fill", color: .systemRed, action: .copy("\(iso.string(from: d)) \(name)"))
        }
    }

    private static func fetchHolidays() async throws -> Any {
        guard let o = try await json("https://holidays-jp.github.io/api/v1/date.json") as? [String: String] else { throw URLError(.cannotParseResponse) }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        return o.compactMap { k, v in df.date(from: k).map { ($0, v) } }.sorted { $0.0 < $1.0 }
    }

    // MARK: Public IP

    func publicIP() -> Answer {
        if age("ip") > 300 { load("ip", kind: "ip", delay: 0) { try await Self.fetchIP() } }
        if let ip: String = cached("ip") {
            return Answer(title: ip, subtitle: "Public IP address", symbol: "globe", color: .systemBlue, action: .copy(ip))
        }
        if let err = failure("ip") { return errorRow("Couldn’t get your public IP", err) }
        return loadingRow("Getting your public IP…", "globe", .systemBlue)
    }

    private static func fetchIP() async throws -> Any {
        guard let ip = (try await json("https://api.ipify.org?format=json") as? [String: Any])?["ip"] as? String else { throw URLError(.cannotParseResponse) }
        return ip
    }

    // MARK: Translation (Claude, only when you press Return)

    private static let languages: [String: String] = [
        "ja": "Japanese", "jp": "Japanese", "japanese": "Japanese", "日本語": "Japanese", "en": "English", "english": "English", "英語": "English",
        "zh": "Simplified Chinese", "cn": "Simplified Chinese", "chinese": "Simplified Chinese", "中国語": "Simplified Chinese", "tw": "Traditional Chinese",
        "ko": "Korean", "kr": "Korean", "korean": "Korean", "韓国語": "Korean", "fr": "French", "french": "French", "フランス語": "French",
        "es": "Spanish", "spanish": "Spanish", "スペイン語": "Spanish", "de": "German", "german": "German", "ドイツ語": "German",
        "it": "Italian", "italian": "Italian", "イタリア語": "Italian", "pt": "Portuguese", "portuguese": "Portuguese", "ポルトガル語": "Portuguese",
        "th": "Thai", "thai": "Thai", "タイ語": "Thai", "vi": "Vietnamese", "vietnamese": "Vietnamese", "ベトナム語": "Vietnamese",
        "id": "Indonesian", "indonesian": "Indonesian", "ru": "Russian", "russian": "Russian", "ロシア語": "Russian", "ar": "Arabic", "arabic": "Arabic",
    ]

    /// "tr hello", "translate こんにちは to french": opens the Translate mode with the text.
    func translation(_ raw: String, target: String?, _ s: Settings, fromClipboard: Bool) -> Answer {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lang = target.map { Self.languages[$0.lowercased()] ?? $0.capitalized }
        let shown = lang ?? (Translator.detect(text) == "English" ? "Japanese" : "English")
        return Answer(title: "Translate “\(Tools.oneLine(text, 80))”", subtitle: "→ \(shown)" + (fromClipboard ? " · copied text" : ""),
                      symbol: "character.bubble.fill", color: .systemPurple,
                      action: .run(keepOpen: true) { Tools.translate(text, lang) }, hint: "Translate ↩")
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - System info and actions

@MainActor enum SystemTools {
    static func answers(_ q: String, _ l: String, _ s: Settings) -> [Answer] {
        if let t = timer(q, l) { return t }
        switch l {
        case "battery", "バッテリー", "電池", "battery health": return battery()
        case "ip", "my ip", "ip address", "ipアドレス", "what is my ip", "what's my ip": return ip()
        case "disk", "storage", "disk space", "free space", "ストレージ", "容量", "空き容量": return disk()
        case "memory", "ram", "メモリ", "memory usage": return memory()
        case "uptime", "稼働時間": return [uptime()]
        case "cpu", "system load", "cpu load": return cpu()
        case "about this mac", "this mac", "system info", "specs", "macos", "macos version", "os version", "このmacについて": return about()
        case "lock", "lock screen", "ロック", "画面ロック", "画面をロック":
            return [run("Lock Screen", "Locks your Mac right away", "lock.fill", lock)]
        case "sleep", "スリープ", "sleep mac", "go to sleep":
            return [run("Sleep", "Puts your Mac to sleep", "moon.zzz.fill", .systemIndigo) { shell("/usr/bin/pmset", ["sleepnow"]) }]
        case "display off", "screen off", "sleep display", "sleep screen", "turn off display", "画面オフ", "ディスプレイオフ":
            return [run("Turn Off Display", "The Mac keeps running", "display", .systemGray) { shell("/usr/bin/pmset", ["displaysleepnow"]) }]
        case "screensaver", "screen saver", "スクリーンセーバー":
            return [run("Start Screen Saver", "", "sparkles.tv", .systemGray) {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app"))
            }]
        case "trash", "ゴミ箱":
            return [run("Open Trash", trashSummary(), "trash", .systemGray) {
                NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
            }]
        case "empty trash", "empty the trash", "ゴミ箱を空にする":
            // Permanent, so it asks first, the way Finder does.
            return [run("Empty Trash", trashSummary(), "trash.fill", .systemGray) {
                let alert = NSAlert()
                alert.messageText = "Empty the Trash?"
                alert.informativeText = "The items will be deleted right away. This can’t be undone."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Empty Trash")
                alert.addButton(withTitle: "Cancel")
                NSApp.activate()
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                osa("tell application \"Finder\" to empty trash")
                Tools.flash("Trash emptied", "", "trash.fill")
            }]
        case "dark mode", "light mode", "toggle dark mode", "appearance", "toggle appearance", "dark", "ダークモード", "ライトモード", "外観":
            return [toggle("dark", "Dark Mode", on: "", off: "", "moon.fill", .systemIndigo,
                           read: { isDark }) { v in setDark(v ? "true" : "false") }]
        case "volume", "vol", "sound", "音量", "ボリューム":
            let m = AudioMixer.shared
            m.refresh()
            let toggle = Answer.Action.run(keepOpen: true) {
                m.setMasterMuted(!m.masterMuted)
                LiveData.shared.onUpdate?()
            }
            return [Answer(title: "Volume \(Int((m.master * 100).rounded()))%", subtitle: m.masterMuted ? "Muted" : "Output volume", symbol: "speaker.wave.2.fill", color: .systemBlue,
                           action: toggle, hint: m.masterMuted ? "Unmute ↩" : "Mute ↩",
                           card: .volume(.init(value: Double(m.master), muted: m.masterMuted, set: { m.setMaster(Float($0)) }, toggleMute: toggle,
                                               chips: [.init(label: "", value: "Volume for each app…", action: .run(keepOpen: true) { Tools.enterScope(.mixer, "") }),
                                                       .init(label: "", value: "25%", action: .run(keepOpen: true) { m.setMaster(0.25); LiveData.shared.onUpdate?() }),
                                                       .init(label: "", value: "50%", action: .run(keepOpen: true) { m.setMaster(0.5); LiveData.shared.onUpdate?() }),
                                                       .init(label: "", value: "100%", action: .run(keepOpen: true) { m.setMaster(1); LiveData.shared.onUpdate?() })])))]
        case "mute", "unmute", "ミュート", "ミュート解除", "消音", "silence":
            return [toggle("mute", "Mute", on: "", off: "", "speaker.slash.fill", .systemBlue,
                           read: { osa("output muted of (get volume settings)", quiet: true) == "true" }) { v in
                osa(v ? "set volume with output muted" : "set volume without output muted")
            }]
        case "volume up", "louder", "vol up", "音量を上げる", "音量アップ":
            return [run("Volume Up", "+10%", "speaker.wave.3.fill", .systemBlue) { changeVolume(10) }]
        case "volume down", "quieter", "vol down", "音量を下げる", "音量ダウン":
            return [run("Volume Down", "−10%", "speaker.wave.1.fill", .systemBlue) { changeVolume(-10) }]
        case "awake", "caffeinate", "keep awake", "stay awake", "no sleep", "don't sleep", "スリープさせない", "スリープ防止", "カフェイン":
            return [toggle("awake", "Keep Awake", on: awakeUntil.map { "Until \(time($0))" } ?? "",
                           off: "", "cup.and.saucer.fill", .systemBrown, read: { awake != 0 }) { v in setAwake(v) }]
        case "night shift", "nightshift", "night light", "night mode", "warm screen", "blue light", "ナイトシフト", "夜間モード":
            guard NightShift.available else { return [] }
            var a = toggle("nightshift", "Night Shift", on: "", off: "", "moon.haze.fill", .systemOrange,
                           read: { NightShift.isOn }) { v in NightShift.set(v) }
            if case .toggle(var sw)? = a.card {
                sw.level = NightShift.strength
                sw.setLevel = { NightShift.setStrength($0) }
                a.card = .toggle(sw)
            }
            return [a]
        case "dock", "hide dock", "autohide dock", "dock autohide", "auto hide dock", "auto-hide dock", "ドック", "dockを隠す":
            return [toggle("dock", "Hide the Dock", on: "", off: "", "dock.rectangle", .systemGray,
                           read: { pref("autohide", "com.apple.dock", default: false) }) { v in
                osa("tell application \"System Events\" to set autohide of dock preferences to \(v)")
            }]
        case "hidden files", "show hidden files", "hide hidden files", "隠しファイル":
            return [toggle("hidden", "Show Hidden Files", on: "", off: "", "eye.fill", .systemGray,
                           read: { pref("AppleShowAllFiles", "com.apple.finder", default: false) }) { v in
                finderPref("AppleShowAllFiles", v)
            }]
        case "desktop icons", "hide desktop icons", "show desktop icons", "clean desktop", "デスクトップアイコン":
            return [toggle("desktop", "Desktop Icons", on: "", off: "", "menubar.dock.rectangle", .systemGray,
                           read: { pref("CreateDesktop", "com.apple.finder", default: true) }) { v in
                finderPref("CreateDesktop", v)
            }]
        case "eject", "eject all", "eject disks", "取り出す", "取り出し":
            let vols = ejectable()
            guard !vols.isEmpty else { return [Answer(title: "No disks to eject", subtitle: "Eject", symbol: "eject.fill")] }
            let names = vols.compactMap { try? $0.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName }
            return [run("Eject \(vols.count == 1 ? names.first ?? "Disk" : "\(vols.count) Disks")", names.joined(separator: ", "), "eject.fill", .systemGray) { eject(vols) }]
        case "hide others", "hide all", "hide other apps", "hide apps", "他を隠す", "ほかを隠す":
            return [run("Hide Other Apps", "Keeps only the app you’re in", "eye.slash.fill", .systemGray) { hideOthers() }]
        case "restart", "reboot", "再起動":
            return [run("Restart…", "macOS asks before restarting", "arrow.clockwise", .systemRed) { osa("tell application \"loginwindow\" to «event aevtrrst»") }]
        case "shut down", "shutdown", "power off", "turn off", "シャットダウン", "電源を切る":
            return [run("Shut Down…", "macOS asks before shutting down", "power", .systemRed) { osa("tell application \"loginwindow\" to «event aevtrsdn»") }]
        case "log out", "logout", "sign out", "ログアウト":
            return [run("Log Out…", "macOS asks before logging out", "rectangle.portrait.and.arrow.right", .systemRed) { osa("tell application \"loginwindow\" to «event aevtlogo»") }]
        default: break
        }
        if let m = Tools.rx(#"^(?:volume|vol|音量)\s*(\d{1,3})\s*%?$"#, l), let v = Int(m[1]) {
            let n = min(100, v)
            return [run("Set Volume to \(n)%", "Output volume", n == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", .systemBlue) {
                osa("set volume output volume \(n)\(n > 0 ? "\nset volume without output muted" : "")")
                Tools.flash("Volume \(n)%", "", "speaker.wave.2.fill")
            }]
        }
        if let m = Tools.rx(#"^(?:awake|caffeinate|keep awake|stay awake)\s+(?:for\s+)?(.+)$"#, l), let mins = minutes(m[1]).value {
            return [run("Keep Awake for \(span(mins))", "Then the Mac can sleep again", "cup.and.saucer.fill", .systemBrown) { setAwake(true, minutes: mins) }]
        }
        return []
    }

    // MARK: Switches (click it or press ↩; the popup stays open and shows the new state)

    /// Recent flips, shown until the system catches up (some settings take a moment to read back).
    private static var flipped: [String: (on: Bool, time: Date)] = [:]

    private static func toggle(_ key: String, _ title: String, on onText: String, off offText: String, _ symbol: String, _ color: NSColor,
                               read: () -> Bool, set: @escaping @MainActor (Bool) -> Void) -> Answer {
        let isOn: Bool
        if let f = flipped[key], Date().timeIntervalSince(f.time) < 3 { isOn = f.on } else { isOn = read() }
        let flip = Answer.Action.run(keepOpen: true) {
            flipped[key] = (!isOn, Date())
            set(!isOn)
            LiveData.shared.onUpdate?()
        }
        let detail = isOn ? onText : offText
        return Answer(title: title, subtitle: detail, symbol: symbol, color: color, action: flip, hint: isOn ? "Turn off ↩" : "Turn on ↩",
                      card: .toggle(.init(title: title, detail: detail, symbol: symbol, color: color, isOn: isOn, toggle: flip)))
    }

    private static func pref(_ key: String, _ app: String, default value: Bool) -> Bool {
        CFPreferencesAppSynchronize(app as CFString)
        let v = CFPreferencesCopyAppValue(key as CFString, app as CFString)
        if let b = v as? Bool { return b }
        if let s = v as? String { return ["1", "yes", "true"].contains(s.lowercased()) }
        if let n = v as? NSNumber { return n.boolValue }
        return value
    }

    private static func finderPref(_ key: String, _ on: Bool) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        p.arguments = ["write", "com.apple.finder", key, "-bool", on ? "true" : "false"]
        p.terminationHandler = { _ in
            DispatchQueue.main.async { shell("/usr/bin/killall", ["Finder"]) }
        }
        try? p.run()
    }

    private static func run(_ title: String, _ sub: String, _ symbol: String, _ color: NSColor, _ f: @escaping @MainActor () -> Void) -> Answer {
        Answer(title: title, subtitle: sub.isEmpty ? nil : sub, symbol: symbol, color: color, action: .run(keepOpen: false, f))
    }

    private static func run(_ title: String, _ sub: String, _ symbol: String, _ f: @escaping @MainActor () -> Void) -> Answer {
        run(title, sub, symbol, .systemGray, f)
    }

    private static func time(_ d: Date) -> String {
        let df = DateFormatter()
        df.timeStyle = .short
        return df.string(from: d)
    }

    // MARK: Timer ("timer 10m", "タイマー 3分", "25 min timer tea")

    /// Minutes in "1h 30m", "90s", "3分", "1.5 hours"; a bare number is minutes. Leftover words are the label.
    static func minutes(_ text: String) -> (value: Double?, label: String) {
        var total = 0.0
        var found = false
        var rest = text
        if let re = try? NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)\s*(hours?|hrs?|h|時間|minutes?|mins?|m|分|seconds?|secs?|s|秒)(?![a-z])"#, options: [.caseInsensitive]) {
            let ns = text as NSString
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let v = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let u = ns.substring(with: m.range(at: 2)).lowercased()
                total += u.hasPrefix("h") || u == "時間" ? v * 60 : u.hasPrefix("s") || u == "秒" ? v / 60 : v
                found = true
            }
            rest = re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        }
        if !found, let m = Tools.rx(#"^\s*(\d+(?:\.\d+)?)\b(.*)$"#, text), let v = Double(m[1]) {
            total = v
            found = true
            rest = m[2]
        }
        let label = rest.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
        return (found && total > 0 && total <= 24 * 60 ? total : nil, label)
    }

    static func span(_ mins: Double) -> String {
        if mins < 1 { return "\(Int((mins * 60).rounded())) sec" }
        let h = Int(mins) / 60, m = Int(mins) % 60
        return h > 0 ? (m > 0 ? "\(h) h \(m) min" : "\(h) h") : "\(Tools.fmt(mins, digits: 1)) min"
    }

    private static func timer(_ q: String, _ l: String) -> [Answer]? {
        guard let m = Tools.rx(#"^(?:timer|タイマー|set a timer for|set timer|countdown)\s+(.+)$"#, q) ?? Tools.rx(#"^(.+?)\s*(?:timer|タイマー)$"#, q) else { return nil }
        let parsed = minutes(m[1])
        guard let mins = parsed.value else { return nil }
        let label = parsed.label.isEmpty ? nil : parsed.label
        let ends = Date().addingTimeInterval(mins * 60)
        var r = run("Start a \(span(mins)) Timer" + (label.map { " · \($0)" } ?? ""), "Rings at \(time(ends))", "timer", .systemOrange) {
            Tools.startTimer(mins, label ?? "")
        }
        r.hint = "Start ↩"
        let presets: [ToolCard.Chip] = [1, 3, 5, 10, 15, 25, 45, 60].filter { Double($0) != mins }.prefix(7).map { m in
            // Fills the bar; Start (or ↩) begins it.
            .init(label: "", value: m == 60 ? "1 h" : "\(m) min", action: .fill("timer \(m)m" + (label.map { " " + $0 } ?? "")))
        }
        r.card = .timer(minutes: mins, label: label, presets: presets)
        return [r]
    }

    // MARK: Info

    private static func battery() -> [Answer] {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return [] }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  d["Type"] as? String == "InternalBattery",
                  let cur = d["Current Capacity"] as? Int, let max = d["Max Capacity"] as? Int, max > 0 else { continue }
            let pct = Int((Double(cur) / Double(max) * 100).rounded())
            let charging = d["Is Charging"] as? Bool ?? false
            let plugged = d["Power Source State"] as? String == "AC Power"
            let toEmpty = d["Time to Empty"] as? Int ?? -1, toFull = d["Time to Full Charge"] as? Int ?? -1
            var sub: String
            if charging {
                sub = "Charging" + (toFull > 0 ? " · full in \(span(Double(toFull)))" : "")
            } else if plugged {
                sub = "Plugged in · not charging"
            } else {
                sub = "On battery" + (toEmpty > 0 ? " · about \(span(Double(toEmpty))) left" : "")
            }
            let level = pct > 87 ? "100" : pct > 62 ? "75" : pct > 37 ? "50" : pct > 12 ? "25" : "0"
            let color: NSColor = pct <= 20 && !plugged ? .systemRed : charging ? .systemGreen : pct <= 40 ? .systemOrange : .systemGreen
            let h = health()
            return [Answer(title: "\(pct)%", subtitle: sub, symbol: "battery.\(level)percent" + (charging ? ".bolt" : ""), color: color,
                           action: .open(URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!), hint: "Battery Settings ↩",
                           card: .gauge(.init(title: "Battery", symbol: "battery.\(level)percent" + (charging ? ".bolt" : ""), color: color, value: "\(pct)%", caption: sub,
                                              fraction: Double(pct) / 100, detail: h.map { "\($0.0) · \($0.1)" })))]
        }
        return [Answer(title: "No battery", subtitle: "This Mac runs on mains power", symbol: "powerplug.fill", color: .systemGray)]
    }

    private static func health() -> (String, String)? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        func prop(_ k: String) -> Int? { (IORegistryEntryCreateCFProperty(service, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue }
        guard let design = prop("DesignCapacity"), design > 0, let maxCap = prop("AppleRawMaxCapacity") ?? prop("NominalChargeCapacity") else { return nil }
        let pct = Int((Double(maxCap) / Double(design) * 100).rounded())
        return ("Health \(min(pct, 100))%", "\(prop("CycleCount").map { "\($0) charge cycles · " } ?? "")\(maxCap) of \(design) mAh")
    }

    private static func ip() -> [Answer] {
        var rows: [Answer] = []
        var addrs: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&addrs) == 0 {
            var p = addrs
            while let a = p {
                defer { p = a.pointee.ifa_next }
                let flags = Int32(a.pointee.ifa_flags)
                guard let sa = a.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), flags & IFF_LOOPBACK == 0, flags & IFF_UP != 0 else { continue }
                let name = String(cString: a.pointee.ifa_name)
                guard name.hasPrefix("en") || name.hasPrefix("bridge") == false && name.hasPrefix("utun") == false else { continue }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
                let addr = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                rows.append(Answer(title: addr, subtitle: "Local IP address · \(name)", symbol: "network", color: .systemBlue, action: .copy(addr)))
            }
            freeifaddrs(addrs)
        }
        return [LiveData.shared.publicIP()] + rows
    }

    private static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    private static func disk() -> [Answer] {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey, .volumeLocalizedNameKey]
        guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys), let total = v.volumeTotalCapacity, total > 0 else { return [] }
        let free = v.volumeAvailableCapacityForImportantUsage ?? 0
        let used = Int(((1 - Double(free) / Double(total)) * 100).rounded())
        let title = "\(bytes(free)) free of \(bytes(Int64(total)))"
        let color: NSColor = used > 90 ? .systemRed : used > 75 ? .systemOrange : .systemBlue
        return [Answer(title: title, subtitle: "\(v.volumeLocalizedName ?? "Macintosh HD") · \(used)% used", symbol: "internaldrive.fill", color: color,
                       action: .open(URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!), hint: "Storage ↩",
                       card: .gauge(.init(title: "Storage · \(v.volumeLocalizedName ?? "Macintosh HD")", symbol: "internaldrive.fill", color: color, value: bytes(free),
                                          caption: "free of \(bytes(Int64(total)))", fraction: Double(used) / 100, detail: "\(used)% used")))]
    }

    private static func memory() -> [Answer] {
        let total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return [] }
        let page = UInt64(getpagesize())
        let app = (UInt64(stats.internal_page_count) - min(UInt64(stats.internal_page_count), UInt64(stats.purgeable_count))) * page
        let wired = UInt64(stats.wire_count) * page, compressed = UInt64(stats.compressor_page_count) * page
        let used = app + wired + compressed
        let mem = { (n: UInt64) in ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .memory) }
        let frac = Double(used) / Double(max(total, 1))
        return [Answer(title: "\(mem(used)) used of \(mem(total))", subtitle: "Apps \(mem(app)) · Wired \(mem(wired)) · Compressed \(mem(compressed))",
                       symbol: "memorychip.fill", color: .systemGray, action: .open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")), hint: "Activity Monitor ↩",
                       card: .gauge(.init(title: "Memory", symbol: "memorychip.fill", color: frac > 0.85 ? .systemOrange : .systemTeal, value: mem(used),
                                          caption: "used of \(mem(total))", fraction: frac, detail: "Apps \(mem(app)) · Wired \(mem(wired)) · Compressed \(mem(compressed))")))]
    }

    private static func uptime() -> Answer {
        let t = ProcessInfo.processInfo.systemUptime
        let f = DateComponentsFormatter()
        f.allowedUnits = t > 86_400 ? [.day, .hour] : [.hour, .minute]
        f.unitsStyle = .full
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return Answer(title: "Up \(f.string(from: t) ?? "")", subtitle: "Since \(df.string(from: Date().addingTimeInterval(-t)))", symbol: "clock.arrow.circlepath", color: .systemGray)
    }

    private static func cpu() -> [Answer] {
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "normal"
        case .fair: thermal = "warm"
        case .serious: thermal = "hot"
        case .critical: thermal = "very hot"
        @unknown default: thermal = "unknown"
        }
        return [Answer(title: "Load \(loads.map { String(format: "%.2f", $0) }.joined(separator: " · "))", subtitle: "1, 5 and 15 min averages · \(ProcessInfo.processInfo.activeProcessorCount) cores · temperature \(thermal)",
                       symbol: "cpu.fill", color: .systemGray, action: .open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")), hint: "Activity Monitor ↩")]
    }

    static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func about() -> [Answer] {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let os = "macOS \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "") + (sysctl("kern.osversion").map { " (\($0))" } ?? "")
        let chip = sysctl("machdep.cpu.brand_string") ?? "Apple silicon"
        let mem = ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory)
        let name = Host.current().localizedName ?? "This Mac"
        let summary = "\(name) · \(chip) · \(mem) · \(os)"
        return [
            Answer(title: name, subtitle: "\(sysctl("hw.model") ?? "Mac") · \(chip)", symbol: "laptopcomputer", color: .systemGray, action: .copy(summary)),
            Answer(title: os, subtitle: "\(ProcessInfo.processInfo.processorCount) cores · \(mem) memory", symbol: "apple.logo", color: .systemGray, action: .copy(os)),
        ]
    }

    // MARK: Actions

    @discardableResult static func osa(_ source: String, quiet: Bool = false) -> String? {
        var err: NSDictionary?
        let r = NSAppleScript(source: source)?.executeAndReturnError(&err)
        if let err {
            if quiet { return nil }
            let msg = err[NSAppleScript.errorMessage] as? String ?? "Couldn’t do that"
            Tools.flash("Didn’t work", msg, "exclamationmark.triangle.fill")
            return nil
        }
        return r?.stringValue
    }

    private static func shell(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try? p.run()
    }

    private static var isDark: Bool {
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleInterfaceStyle"] as? String == "Dark"
    }

    private static func setDark(_ value: String) {
        osa("tell application \"System Events\" to tell appearance preferences to set dark mode to \(value)")
    }

    private static func changeVolume(_ delta: Int) {
        let now = Int(osa("output volume of (get volume settings)") ?? "") ?? 50
        let n = min(100, max(0, now + delta))
        osa("set volume output volume \(n)\nset volume without output muted")
        Tools.flash("Volume \(n)%", "", "speaker.wave.2.fill")
    }

    private static func lock() {
        typealias Lock = @convention(c) () -> Int32
        if let h = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW), let sym = dlsym(h, "SACLockScreenImmediate") {
            _ = unsafeBitCast(sym, to: Lock.self)()
            return
        }
        // ⌃⌘Q
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 12, keyDown: down)
            e?.flags = [.maskControl, .maskCommand]
            e?.post(tap: .cghidEventTap)
        }
    }

    private static func trashSummary() -> String {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return "Deletes everything in the Trash" }
        let n = items.filter { $0 != ".DS_Store" }.count
        return n == 0 ? "The Trash is already empty" : "Deletes \(n) item\(n == 1 ? "" : "s") for good"
    }

    private static func ejectable() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey, .volumeIsRootFileSystemKey]
        return (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []).filter { v in
            guard let r = try? v.resourceValues(forKeys: Set(keys)), r.volumeIsRootFileSystem != true, v.path.hasPrefix("/Volumes/") else { return false }
            return r.volumeIsEjectable == true || r.volumeIsRemovable == true || r.volumeIsInternal == false
        }
    }

    private static func eject(_ vols: [URL]) {
        var failed: [String] = []
        for v in vols {
            do { try NSWorkspace.shared.unmountAndEjectDevice(at: v) } catch { failed.append(v.lastPathComponent) }
        }
        if failed.isEmpty {
            Tools.flash("Ejected", vols.count == 1 ? vols[0].lastPathComponent : "\(vols.count) disks", "eject.fill")
        } else {
            Tools.flash("Couldn’t eject", failed.joined(separator: ", ") + " is in use", "exclamationmark.triangle.fill")
        }
    }

    private static func hideOthers() {
        let front = NSWorkspace.shared.frontmostApplication
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app != front && app != NSRunningApplication.current {
            app.hide()
        }
    }

    // Keep awake

    private static var awake: IOPMAssertionID = 0
    private static var awakeUntil: Date?
    private static var awakeTimer: Timer?

    static func setAwake(_ on: Bool, minutes: Double? = nil) {
        if awake != 0 {
            IOPMAssertionRelease(awake)
            awake = 0
        }
        awakeTimer?.invalidate()
        awakeTimer = nil
        awakeUntil = nil
        guard on else {
            Tools.flash("Sleep allowed again", "", "moon.zzz.fill")
            return
        }
        var id: IOPMAssertionID = 0
        guard IOPMAssertionCreateWithName("PreventUserIdleDisplaySleep" as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                          "MONEY! keep awake" as CFString, &id) == kIOReturnSuccess else { return }
        awake = id
        if let minutes {
            awakeUntil = Date().addingTimeInterval(minutes * 60)
            awakeTimer = Timer.scheduledTimer(withTimeInterval: minutes * 60, repeats: false) { _ in
                MainActor.assumeIsolated { setAwake(false) }
            }
        }
        Tools.flash("Keeping your Mac awake", minutes.map { "for \(span($0))" } ?? "until you turn it off", "cup.and.saucer.fill")
    }
}
