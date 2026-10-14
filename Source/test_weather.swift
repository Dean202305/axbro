import Foundation

@main struct WeatherTests {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ title: String) {
            precondition(value, title)
            checks += 1
        }
        func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

        // A long first day used to shadow tomorrow's sunrise until 08:00.
        let hour = 3600.0
        var reading = WeatherReading(temperature: 18, code: 0,
                                     sunrise: [6 * hour, 30 * hour],
                                     sunset: [20 * hour, 44 * hour], fetchedAt: 0)
        check(!reading.isDay(at: date(6 * hour - 1)), "Before sunrise is night")
        check(reading.isDay(at: date(6 * hour)), "Sunrise begins daytime")
        check(reading.isDay(at: date(20 * hour - 1)), "Before sunset remains daytime")
        check(!reading.isDay(at: date(20 * hour)), "Sunset begins night")
        check(!reading.isDay(at: date(30 * hour - 1)), "Tomorrow before sunrise is night")
        check(reading.isDay(at: date(30 * hour)), "Tomorrow sunrise must not use yesterday's interval")
        check(reading.isDay(at: date(30.5 * hour)), "Tomorrow morning must remain daytime")
        check(!reading.isDay(at: date(44 * hour)), "Tomorrow sunset begins night")
        check(reading.presentation(at: date(30.5 * hour)).icon == .reference(5), "Tomorrow clear sky uses sun")
        check(reading.presentation(at: date(29 * hour)).icon == .moon, "Night clear sky uses moon")

        let mappings: [(Int, Int, String)] = [
            (0, 5, "晴"), (1, 10, "晴间多云"), (2, 9, "多云"), (3, 6, "阴"),
            (45, 8, "雾"), (48, 8, "雾凇"),
            (51, 1, "毛毛雨"), (53, 1, "毛毛雨"), (55, 1, "毛毛雨"),
            (56, 12, "冻毛毛雨"), (57, 12, "冻毛毛雨"),
            (61, 11, "小雨"), (63, 11, "中雨"), (65, 11, "大雨"),
            (66, 12, "冻雨"), (67, 12, "冻雨"),
            (71, 13, "小雪"), (73, 13, "中雪"), (75, 13, "大雪"), (77, 7, "雪粒"),
            (80, 11, "阵雨"), (81, 11, "阵雨"), (82, 11, "强阵雨"),
            (85, 3, "阵雪"), (86, 3, "阵雪"),
            (95, 14, "雷雨"), (96, 14, "雷雨冰雹"), (97, 14, "强雷雨"), (99, 14, "雷雨冰雹")
        ]
        for (code, artwork, label) in mappings {
            let day = WeatherPresentation.make(code: code, isDay: true)
            let night = WeatherPresentation.make(code: code, isDay: false)
            check(day.icon == .reference(artwork), "Daytime artwork for WMO \(code)")
            check(day.label == label && night.label == label, "Weather label follows condition for WMO \(code)")
            check(day.isDay && !night.isDay, "Day/night state is retained for WMO \(code)")
            if code == 0 {
                check(night.icon == .moon, "Clear sky changes to moon at night")
            } else if code == 1 || code == 2 {
                check(night.icon == .moonCloud, "Partial cloud changes to moon/cloud at night")
            } else {
                check(night.icon == day.icon, "Non-solar weather keeps its condition at night for WMO \(code)")
            }
        }
        check(WeatherKind(code: 97) == .thunder, "Heavy thunderstorm also drives thunder background")
        for code: Int? in [nil, -1, 999] {
            let unknown = WeatherPresentation.make(code: code, isDay: false)
            check(unknown.icon == .reference(15) && unknown.label == "天气未知", "Unknown weather has honest glyph and label")
        }

        let oldJSON = #"{"current":{"temperature_2m":15.4,"weather_code":0},"daily":{"sunrise":[21600,108000],"sunset":[72000,158400]}}"#
        let old = try JSONDecoder().decode(WeatherResponse.self, from: Data(oldJSON.utf8)).reading(now: 100)
        check(old.reportedIsDay == nil && old.reportedAt == nil && old.timezoneIdentifier == nil,
              "Older API/preview JSON remains readable without new fields")
        check(old.temperature == 15.4 && old.presentation(at: date(108000)).icon == .reference(5),
              "Old JSON still uses absolute sunrise boundaries")

        let newJSON = #"{"timezone":"Asia/Shanghai","current":{"temperature_2m":16,"weather_code":97,"is_day":0,"time":200000},"daily":{"sunrise":[],"sunset":[]}}"#
        let new = try JSONDecoder().decode(WeatherResponse.self, from: Data(newJSON.utf8)).reading(now: 200005)
        check(new.reportedIsDay == false && new.reportedAt == 200000 && new.timezoneIdentifier == "Asia/Shanghai",
              "New current weather and timezone fields are retained")
        check(!new.isDay(at: date(200000)), "Fresh API is_day is used when solar intervals are absent")
        check(new.presentation(at: date(200000)).label == "强雷雨", "New WMO 97 is labeled")
        let invalidDayJSON = newJSON.replacingOccurrences(of: "\"is_day\":0", with: "\"is_day\":2")
        let invalidDay = try JSONDecoder().decode(WeatherResponse.self, from: Data(invalidDayJSON.utf8)).reading(now: 200005)
        check(invalidDay.reportedIsDay == nil, "Invalid API is_day cannot become a false night report")

        let noonUTC = ISO8601DateFormatter().date(from: "2026-10-14T12:00:00Z")!
        reading.sunrise = []; reading.sunset = []
        reading.timezoneIdentifier = "Asia/Shanghai"
        check(!reading.isDay(at: noonUTC), "Missing solar data uses location timezone: Beijing 20:00 is night")
        reading.timezoneIdentifier = "Europe/London"
        check(reading.isDay(at: noonUTC), "Same absolute instant is daytime in London")
        reading.reportedAt = noonUTC.timeIntervalSince1970
        reading.reportedIsDay = false
        check(!reading.isDay(at: noonUTC), "Fresh API night report takes precedence over clock fallback")
        reading.reportedAt = noonUTC.timeIntervalSince1970 - 3600
        check(reading.isDay(at: noonUTC), "Stale API report cannot freeze the day/night state")
        reading.reportedAt = noonUTC.timeIntervalSince1970
        reading.reportedIsDay = true
        reading.timezoneIdentifier = "Asia/Shanghai"
        check(reading.isDay(at: noonUTC), "Fresh API daylight report takes precedence over clock fallback")
        reading.reportedIsDay = nil; reading.reportedAt = nil
        reading.sunrise = [.nan, 100]; reading.sunset = [.infinity, 99]
        check(!reading.isDay(at: noonUTC), "Invalid solar pairs are ignored safely")

        // Presentation deliberately takes only weather and daylight, so changing
        // panel transparency cannot select a different icon or weather label.
        print("Passed \(checks) weather mapping, sunrise, API compatibility and fallback checks")
    }
}
