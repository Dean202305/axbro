import AppKit
import SwiftUI
import CoreLocation
import Combine

enum WeatherKind: String, Codable {
    case clear, cloudy, fog, rain, snow, thunder, unknown
    init(code: Int) {
        switch code {
        case 0, 1: self = .clear
        case 2, 3: self = .cloudy
        case 45, 48: self = .fog
        case 51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 80, 81, 82: self = .rain
        case 71, 73, 75, 77, 85, 86: self = .snow
        case 95, 96, 97, 99: self = .thunder
        default: self = .unknown
        }
    }
    var title: String {
        switch self {
        case .clear: return "晴"
        case .cloudy: return "多云"
        case .fog: return "雾"
        case .rain: return "雨"
        case .snow: return "雪"
        case .thunder: return "雷雨"
        case .unknown: return "天气未知"
        }
    }
    func symbol(day: Bool) -> String {
        switch self {
        case .clear: return day ? "sun.max.fill" : "moon.stars.fill"
        case .cloudy: return day ? "cloud.sun.fill" : "cloud.moon.fill"
        case .fog: return "cloud.fog.fill"
        case .rain: return "cloud.rain.fill"
        case .snow: return "cloud.snow.fill"
        case .thunder: return "cloud.bolt.rain.fill"
        case .unknown: return "location"
        }
    }
}

struct WeatherPresentation: Equatable {
    enum Icon: Equatable { case reference(Int), moon, moonCloud }
    let icon: Icon
    let label: String
    let isDay: Bool

    static func make(code: Int?, isDay: Bool) -> WeatherPresentation {
        let icon: Icon
        let label: String
        switch code {
        case 0: icon = isDay ? .reference(5) : .moon; label = "晴"
        case 1: icon = isDay ? .reference(10) : .moonCloud; label = "晴间多云"
        case 2: icon = isDay ? .reference(9) : .moonCloud; label = "多云"
        case 3: icon = .reference(6); label = "阴"
        case 45: icon = .reference(8); label = "雾"
        case 48: icon = .reference(8); label = "雾凇"
        case 51, 53, 55: icon = .reference(1); label = "毛毛雨"
        case 56, 57: icon = .reference(12); label = "冻毛毛雨"
        case 61: icon = .reference(11); label = "小雨"
        case 63: icon = .reference(11); label = "中雨"
        case 65: icon = .reference(11); label = "大雨"
        case 66, 67: icon = .reference(12); label = "冻雨"
        case 71: icon = .reference(13); label = "小雪"
        case 73: icon = .reference(13); label = "中雪"
        case 75: icon = .reference(13); label = "大雪"
        case 77: icon = .reference(7); label = "雪粒"
        case 80, 81: icon = .reference(11); label = "阵雨"
        case 82: icon = .reference(11); label = "强阵雨"
        case 85, 86: icon = .reference(3); label = "阵雪"
        case 95: icon = .reference(14); label = "雷雨"
        case 97: icon = .reference(14); label = "强雷雨"
        case 96, 99: icon = .reference(14); label = "雷雨冰雹"
        default: icon = .reference(15); label = "天气未知"
        }
        return WeatherPresentation(icon: icon, label: label, isDay: isDay)
    }
}

struct WeatherReading: Codable {
    var temperature: Double
    var code: Int
    var sunrise: [Double]
    var sunset: [Double]
    var fetchedAt: Double
    var timezoneIdentifier: String? = nil
    var reportedIsDay: Bool? = nil
    var reportedAt: Double? = nil
    var kind: WeatherKind { WeatherKind(code: code) }
    func isDay(at date: Date) -> Bool {
        let time = date.timeIntervalSince1970
        let intervals = zip(sunrise, sunset).filter { $0.0.isFinite && $0.1.isFinite && $0.1 > $0.0 }
        // Check every daylight interval before interpreting the gaps as night.
        // Yesterday's extended night window must not hide today's sunrise.
        if intervals.contains(where: { time >= $0.0 && time < $0.1 }) { return true }
        if let first = intervals.map({ $0.0 }).min(), let last = intervals.map({ $0.1 }).max(),
           time >= first - 12 * 3600 && time <= last + 12 * 3600 { return false }
        if let reportedIsDay = reportedIsDay, let reportedAt = reportedAt,
           abs(time - reportedAt) < 3600 { return reportedIsDay }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent
        return (6..<18).contains(calendar.component(.hour, from: date))
    }
    func presentation(at date: Date) -> WeatherPresentation {
        WeatherPresentation.make(code: code, isDay: isDay(at: date))
    }
}

struct WeatherResponse: Decodable {
    struct Current: Decodable {
        let temperature_2m: Double
        let weather_code: Int
        let is_day: Int?
        let time: Double?
    }
    struct Daily: Decodable { let sunrise: [Double]; let sunset: [Double] }
    let current: Current
    let daily: Daily
    let timezone: String?
    func reading(now: Double) -> WeatherReading {
        WeatherReading(temperature: current.temperature_2m, code: current.weather_code,
                       sunrise: daily.sunrise, sunset: daily.sunset, fetchedAt: now,
                       timezoneIdentifier: timezone, reportedIsDay: current.is_day.flatMap { value -> Bool? in
                           value == 1 ? true : value == 0 ? false : nil
                       },
                       reportedAt: current.time)
    }
}

final class WeatherController: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var reading: WeatherReading?
    @Published var place = "当前位置"
    @Published var message = "等待定位"
    @Published private(set) var authorizationMessage = "未授权"
    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var lastLocation: CLLocation?
    private var timer: Timer?
    private var request: URLSessionDataTask?
    private var requestGeneration = 0
    private var started = false
    private var asked = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        updateAuthorizationMessage()
    }

    func start() {
        guard !started else { return }
        started = true
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        switch manager.authorizationStatus {
        case .notDetermined:
            message = "等待定位授权"
            if !asked {
                asked = true
                NSApplication.shared.activate(ignoringOtherApps: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.manager.requestWhenInUseAuthorization() }
            }
        case .denied, .restricted:
            reading = nil
            message = "定位未授权"
        case .authorizedAlways, .authorizedWhenInUse:
            message = reading == nil ? "正在定位" : message
            manager.requestLocation()
        @unknown default:
            message = "定位暂不可用"
        }
    }

    private func updateAuthorizationMessage() {
        switch manager.authorizationStatus {
        case .notDetermined: authorizationMessage = "未授权"
        case .denied, .restricted: authorizationMessage = "未允许"
        case .authorizedAlways, .authorizedWhenInUse: authorizationMessage = "已允许"
        @unknown default: authorizationMessage = "未知"
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        updateAuthorizationMessage()
        if started { refresh() }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard started, let location = locations.last, location.horizontalAccuracy >= 0,
              abs(location.timestamp.timeIntervalSinceNow) < 300 else { return }
        let moved = lastLocation.map { location.distance(from: $0) > 5000 } ?? true
        lastLocation = location
        if moved {
            geocoder.cancelGeocode()
            geocoder.reverseGeocodeLocation(location, preferredLocale: Locale(identifier: "zh_CN")) { [weak self] places, _ in
                DispatchQueue.main.async {
                    if let first = places?.first { self?.place = first.locality ?? first.administrativeArea ?? "当前位置" }
                }
            }
        }
        fetch(location.coordinate)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard started else { return }
        message = reading == nil ? "定位暂不可用" : "上次天气"
        // A previous authorized coordinate can still refresh weather without inventing a location.
        if let location = lastLocation { fetch(location.coordinate) }
    }

    private func fetch(_ coordinate: CLLocationCoordinate2D) {
        guard request == nil else { return }
        guard var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast") else { return }
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.2f", coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.2f", coordinate.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "sunrise,sunset"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "forecast_days", value: "2")
        ]
        guard let url = components.url else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        requestGeneration += 1
        let generation = requestGeneration
        request = URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            DispatchQueue.main.async {
                guard let self = self, self.started, self.requestGeneration == generation else { return }
                self.request = nil
                guard (response as? HTTPURLResponse)?.statusCode == 200, let data = data,
                      let value = try? JSONDecoder().decode(WeatherResponse.self, from: data),
                      value.current.temperature_2m.isFinite else {
                    self.message = self.reading == nil ? "天气暂不可用" : "上次天气"
                    return
                }
                self.reading = value.reading(now: Date().timeIntervalSince1970)
                self.message = ""
            }
        }
        request?.resume()
    }

    func openLocationSettings() {
        if manager.authorizationStatus == .notDetermined { asked = false; refresh() }
        else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    func stop() {
        started = false
        requestGeneration += 1
        timer?.invalidate(); timer = nil
        request?.cancel(); request = nil
        manager.stopUpdatingLocation(); geocoder.cancelGeocode()
    }
}

struct WeatherBackdrop: View {
    let reading: WeatherReading?
    let now: Date
    var opacity: Double = 0.5
    var showsArtwork = true
    private var day: Bool { reading?.isDay(at: now) ?? (6..<18).contains(Calendar.current.component(.hour, from: now)) }
    var body: some View {
        Canvas { context, size in
            let kind = reading?.kind ?? .unknown
            let upper: Color
            if !day { upper = Color(red: 0.08, green: 0.10, blue: 0.29) }
            else if kind == .rain || kind == .thunder { upper = Color(red: 0.18, green: 0.25, blue: 0.34) }
            else if kind == .snow || kind == .fog { upper = Color(red: 0.28, green: 0.39, blue: 0.46) }
            else { upper = Color(red: 0.10, green: 0.32, blue: 0.49) }
            let bottom = Color(red: 0.035, green: 0.075, blue: 0.15)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(Gradient(colors: [upper, bottom]), startPoint: .zero, endPoint: CGPoint(x: size.width * 0.3, y: size.height)))
            if kind != .unknown && showsArtwork {
                if !day && (kind == .clear || kind == .cloudy) {
                    for i in 0..<26 {
                        let x = CGFloat((i * 67 + 19) % 300) / 300 * size.width
                        let y = CGFloat((i * 41 + 13) % 120)
                        context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.5, height: 1.5)), with: .color(.white.opacity(0.55)))
                    }
                }
                if kind == .rain || kind == .thunder {
                    for i in 0..<25 {
                        let x = CGFloat((i * 47 + 17) % 300) / 300 * size.width
                        let y = CGFloat((i * 31 + 60) % 260)
                        var path = Path(); path.move(to: CGPoint(x: x, y: y)); path.addLine(to: CGPoint(x: x - 5, y: y + 14))
                        context.stroke(path, with: .color(.white.opacity(0.18)), lineWidth: 1)
                    }
                } else if kind == .snow {
                    for i in 0..<32 {
                        let x = CGFloat((i * 53 + 11) % 300) / 300 * size.width
                        let y = CGFloat((i * 37 + 20) % 270)
                        context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 2.5, height: 2.5)), with: .color(.white.opacity(0.4)))
                    }
                } else if kind == .fog {
                    for i in 0..<5 {
                        let rect = CGRect(x: -20, y: CGFloat(i * 38 + 40), width: size.width + 40, height: 18)
                        context.fill(Path(roundedRect: rect, cornerRadius: 9), with: .color(.white.opacity(0.10)))
                    }
                }
            }
        }.opacity(opacity).accessibilityHidden(true)
    }
}

/// The same weather and daylight selection is used at every transparency level.
struct WeatherBadge: View {
    let reading: WeatherReading?
    let now: Date
    private var presentation: WeatherPresentation {
        reading?.presentation(at: now) ?? WeatherPresentation.make(code: nil, isDay: true)
    }
    var body: some View {
        VStack(spacing: 2) {
            OutlineWeatherIcon(presentation: presentation).frame(width: 34, height: 34)
            Text(presentation.label).font(.system(size: 8.5, weight: .medium))
                .foregroundColor(.white.opacity(0.86)).lineLimit(1).minimumScaleFactor(0.8)
                .frame(width: 48)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(presentation.label)，\(presentation.isDay ? "白天" : "夜间")")
        .allowsHitTesting(false)
    }
}

/// Reference sprites stay aspect-fit; night variants reuse the original cloud.
struct OutlineWeatherIcon: View {
    let presentation: WeatherPresentation
    var body: some View {
        Group {
            switch presentation.icon {
            case .reference(let key):
                reference(key)
            case .moon:
                CrescentWeatherIcon()
            case .moonCloud:
                ZStack {
                    CrescentWeatherIcon().frame(width: 23, height: 23).position(x: 23, y: 11.5)
                    reference(6).frame(width: 31, height: 23).position(x: 15.5, y: 22.5)
                }.frame(width: 34, height: 34)
            }
        }.accessibilityHidden(true).allowsHitTesting(false)
    }
    @ViewBuilder private func reference(_ key: Int) -> some View {
        if let image = ReferenceWeatherArtwork.images[key] {
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
        }
    }
}

struct CrescentWeatherIcon: View {
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 34
            let outer = CGPoint(x: 17 * scale, y: 17 * scale)
            let inner = CGPoint(x: 27 * scale, y: 11 * scale)
            let distance = sqrt(136.0)
            let height = sqrt(191.0)
            let top = CGPoint(x: (22 - height * 6 / distance) * scale, y: (14 - height * 10 / distance) * scale)
            let bottom = CGPoint(x: (22 + height * 6 / distance) * scale, y: (14 + height * 10 / distance) * scale)
            var moon = Path()
            moon.addArc(center: outer, radius: 15 * scale,
                        startAngle: .radians(atan2(top.y - outer.y, top.x - outer.x)),
                        endAngle: .radians(atan2(bottom.y - outer.y, bottom.x - outer.x)), clockwise: true)
            moon.addArc(center: inner, radius: 15 * scale,
                        startAngle: .radians(atan2(bottom.y - inner.y, bottom.x - inner.x)),
                        endAngle: .radians(atan2(top.y - inner.y, top.x - inner.x)), clockwise: false)
            moon.closeSubpath()
            context.fill(moon, with: .color(Color(red: 0.84, green: 0.86, blue: 0.92)))
        }
    }
}

enum ReferenceWeatherArtwork {
    static func key(code: Int?) -> Int {
        switch code {
        case 0: return 5
        case 1: return 10
        case 2: return 9
        case 3: return 6
        case 45, 48: return 8
        case 51, 53, 55: return 1
        case 56, 57, 66, 67: return 12
        case 61, 63, 65, 80, 81, 82: return 11
        case 71, 73, 75: return 13
        case 77: return 7
        case 85, 86: return 3
        case 95, 96, 97, 99: return 14
        default: return 15
        }
    }

    static let images: [Int: NSImage] = {
        guard let url = Bundle.main.url(forResource: "WeatherReference", withExtension: "png"),
              let source = NSImage(contentsOf: url),
              let sheet = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [:] }
        let columns = [58, 220, 380, 548]
        let rows = [36, 216, 407, 604]
        var result: [Int: NSImage] = [:]
        for index in 0..<16 {
            let height = index / 4 == 3 ? 122 : 140
            let rect = CGRect(x: columns[index % 4], y: rows[index / 4], width: 140, height: height)
            guard let crop = sheet.cropping(to: rect),
                  let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 140, pixelsHigh: height,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bitmapFormat: [], bytesPerRow: 560, bitsPerPixel: 32),
                  let pixels = bitmap.bitmapData,
                  let context = CGContext(data: pixels, width: 140, height: height, bitsPerComponent: 8, bytesPerRow: 560,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 140, height: height))
            // Recover fractional coverage from the sheet's original ink colours.
            // Premultiplied output removes the dark matte instead of preserving it at edges.
            let background = (0..<3).map { channel -> Double in
                let corners = [0, 139 * 4, (height - 1) * 560, (height - 1) * 560 + 139 * 4]
                return Double(corners.map { Int(pixels[$0 + channel]) }.sorted()[1])
            }
            var swatches = [[[Double]]] (repeating: [], count: 3)
            for offset in stride(from: 0, to: height * 560, by: 4) {
                let rgb = (0..<3).map { Double(pixels[offset + $0]) }
                if rgb.min()! > 200 && rgb.max()! - rgb.min()! < 35 { swatches[0].append(rgb) }
                else if rgb[0] > 180 && rgb[0] > rgb[1] * 1.15 && rgb[1] > rgb[2] * 1.5 { swatches[1].append(rgb) }
                else if rgb[2] > 140 && rgb[1] > rgb[0] * 1.3 && rgb[2] > rgb[0] * 1.3 { swatches[2].append(rgb) }
            }
            let fallback = [[246.0, 247, 246], [246.0, 177, 48], [88.0, 174, 202]]
            let palette = swatches.enumerated().map { index, samples -> [Double] in
                guard samples.count >= 8 else { return fallback[index] }
                return (0..<3).map { channel in samples.map { $0[channel] }.sorted()[samples.count / 2] }
            }
            var coverage = [Double](repeating: 0, count: 140 * height)
            var ink = [Int](repeating: 0, count: coverage.count)
            for pixel in coverage.indices {
                let rgb = (0..<3).map { Double(pixels[pixel * 4 + $0]) }
                var bestError = Double.infinity
                for (index, colour) in palette.enumerated() {
                    let vector = (0..<3).map { colour[$0] - background[$0] }
                    let dot = (0..<3).reduce(0.0) { $0 + (rgb[$1] - background[$1]) * vector[$1] }
                    let norm = vector.reduce(0.0) { $0 + $1 * $1 }
                    let alpha = min(1, max(0, dot / norm))
                    let error = (0..<3).reduce(0.0) { total, channel in
                        let residual = rgb[channel] - background[channel] - alpha * vector[channel]
                        return total + residual * residual
                    }
                    if error < bestError { bestError = error; coverage[pixel] = alpha; ink[pixel] = index }
                }
            }
            // Retain connected linework with a solid core, including its soft edge.
            // Isolated compression noise has neither enough area nor a strong core.
            var visited = [Bool](repeating: false, count: coverage.count)
            var keep = [Bool](repeating: false, count: coverage.count)
            for start in coverage.indices where !visited[start] && coverage[start] >= 0.08 {
                var component = [start]
                visited[start] = true
                var cursor = 0, hasCore = false
                while cursor < component.count {
                    let pixel = component[cursor]; cursor += 1
                    hasCore = hasCore || coverage[pixel] >= 0.55
                    let x = pixel % 140, y = pixel / 140
                    for dy in -1...1 {
                        for dx in -1...1 where dx != 0 || dy != 0 {
                            let nx = x + dx, ny = y + dy
                            guard nx >= 0, nx < 140, ny >= 0, ny < height else { continue }
                            let neighbour = ny * 140 + nx
                            if !visited[neighbour] && coverage[neighbour] >= 0.08 {
                                visited[neighbour] = true; component.append(neighbour)
                            }
                        }
                    }
                }
                if hasCore && component.count >= 5 { for pixel in component { keep[pixel] = true } }
            }
            var minX = 140, minY = height, maxX = 0, maxY = 0
            for pixel in coverage.indices {
                let alpha = keep[pixel] ? coverage[pixel] : 0
                for channel in 0..<3 {
                    pixels[pixel * 4 + channel] = UInt8((palette[ink[pixel]][channel] * alpha).rounded())
                }
                pixels[pixel * 4 + 3] = UInt8((alpha * 255).rounded())
                if alpha > 0 {
                    let x = pixel % 140, y = pixel / 140
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            guard minX <= maxX, minY <= maxY, let cg = bitmap.cgImage,
                  let trimmed = cg.cropping(to: CGRect(x: max(0, minX - 2), y: max(0, minY - 2),
                    width: min(140 - max(0, minX - 2), maxX - minX + 5),
                    height: min(height - max(0, minY - 2), maxY - minY + 5))) else { continue }
            result[index] = NSImage(cgImage: trimmed, size: NSSize(width: trimmed.width, height: trimmed.height))
        }
        return result
    }()
}
