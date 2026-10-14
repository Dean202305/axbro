import Foundation

enum ReminderEvent: String, Equatable {
    case lowUsage
    case resetDue
}

struct ReminderHistory: Codable, Equatable {
    var lowWindow: Double?
    var lastReset: Double?
}

/// Uses actual remaining quota, not the rounded percentage displayed in the menu bar.
/// A fresh quota snapshot arms the reset deadline; the local clock fires it even if a later read is offline.
struct ReminderPolicy {
    var history = ReminderHistory()
    private(set) var pendingReset: Double?

    mutating func observe(remaining: Double?, resetAt: Double?, windowMinutes: Int?, fresh: Bool, now: Double) -> [ReminderEvent] {
        var events = tick(now: now)
        guard fresh else { return events }
        let deadline = resetAt.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        if windowMinutes == 300, let deadline = deadline, deadline > now {
            pendingReset = deadline
        } else {
            pendingReset = nil
        }
        guard let remaining = remaining, remaining.isFinite, remaining >= 0, remaining <= 100 else { return events }
        if remaining >= 5 {
            history.lowWindow = nil
        } else if deadline == nil || deadline! > now {
            let window = deadline ?? 0
            if history.lowWindow != window {
                history.lowWindow = window
                events.append(.lowUsage)
            }
        }
        return events
    }

    mutating func tick(now: Double) -> [ReminderEvent] {
        guard let deadline = pendingReset, now >= deadline else { return [] }
        pendingReset = nil
        guard history.lastReset != deadline else { return [] }
        history.lastReset = deadline
        return [.resetDue]
    }
}
