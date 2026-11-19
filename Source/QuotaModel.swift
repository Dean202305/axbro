import Foundation

struct QuotaWindow: Decodable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Double?
    var remaining: Double { max(0, min(100, 100 - usedPercent)) }
    var percent: String { "\(Int(remaining.rounded()))%" }
    var resetDate: Date? { resetsAt.map(Date.init(timeIntervalSince1970:)) }
    var period: String {
        guard let m = windowDurationMins, m > 0 else { return "未提供" }
        if m % 1440 == 0 { return "\(m / 1440) 天" }
        if m % 60 == 0 { return "\(m / 60) 小时" }
        return "\(m) 分钟"
    }
    var label: String {
        guard let minutes = windowDurationMins else { return "当前窗口剩余用量" }
        if minutes == 10080 { return "每周剩余" }
        if minutes % 60 == 0 { return "\(minutes / 60) 小时剩余用量" }
        return "\(minutes) 分钟剩余用量"
    }
}

struct Usage: Decodable {
    let primary: QuotaWindow?
    let secondary: QuotaWindow?
    let resetCount: Int?
    let plan: String?
    let allowed: Bool?
    var windows: [QuotaWindow] {
        [primary, secondary].compactMap { $0 }.filter { $0.usedPercent.isFinite && $0.usedPercent >= 0 && $0.usedPercent <= 100 }
            .sorted { ($0.windowDurationMins ?? Int.max) < ($1.windowDurationMins ?? Int.max) }
    }
    var mainWindow: QuotaWindow? { windows.first }
    var otherWindow: QuotaWindow? { windows.count > 1 ? windows[1] : nil }
    var planTitle: String {
        guard let plan = plan, !plan.isEmpty else { return "套餐未知" }
        if plan.lowercased().hasPrefix("pro") { return "Pro" }
        switch plan.lowercased() {
        case "plus": return "Plus"
        case "free": return "Free"
        case "team", "business": return "Business"
        case "enterprise": return "Enterprise"
        case "edu": return "Edu"
        default: return plan
        }
    }
}

