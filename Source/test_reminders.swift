import Foundation

@main struct ReminderTests {
    static func main() {
        var checks = 0
        func check(_ value: Bool, _ title: String) {
            precondition(value, title)
            checks += 1
        }
        var p = ReminderPolicy()
        check(p.observe(remaining: 5, resetAt: 200, windowMinutes: 300, fresh: true, now: 100).isEmpty, "Exactly 5 must not alarm")
        check(p.observe(remaining: 4.9, resetAt: 200, windowMinutes: 300, fresh: true, now: 101) == [.lowUsage], "Raw quota below 5 alarms")
        check(p.observe(remaining: 4, resetAt: 200, windowMinutes: 300, fresh: true, now: 106).isEmpty, "Polling must not repeat alarm")
        check(p.tick(now: 199).isEmpty, "Reset must not fire early")
        check(p.tick(now: 200) == [.resetDue], "Reset fires at deadline")
        check(p.tick(now: 201).isEmpty, "Reset must not repeat")
        check(p.observe(remaining: 3, resetAt: 200, windowMinutes: 300, fresh: true, now: 205).isEmpty, "Expired quota is not a new low alarm")
        check(p.observe(remaining: 100, resetAt: 500, windowMinutes: 300, fresh: true, now: 206).isEmpty, "Recovery re-arms quietly")
        check(p.observe(remaining: 1, resetAt: 500, windowMinutes: 300, fresh: false, now: 207).isEmpty, "Stale quota cannot trigger low warning")
        check(p.observe(remaining: 4, resetAt: 500, windowMinutes: 300, fresh: true, now: 208) == [.lowUsage], "New quota cycle alarms")
        var restarted = ReminderPolicy(history: p.history)
        check(restarted.observe(remaining: 4, resetAt: 500, windowMinutes: 300, fresh: true, now: 210).isEmpty, "Restart deduplicates low alarm")
        check(restarted.observe(remaining: nil, resetAt: nil, windowMinutes: nil, fresh: false, now: 500) == [.resetDue], "Armed deadline works while offline")
        var manual = ReminderPolicy()
        _ = manual.observe(remaining: 10, resetAt: 200, windowMinutes: 300, fresh: true, now: 100)
        _ = manual.observe(remaining: 100, resetAt: 400, windowMinutes: 300, fresh: true, now: 110)
        check(manual.tick(now: 200).isEmpty, "An early manual reset replaces the old deadline")
        check(manual.tick(now: 400) == [.resetDue], "New deadline fires")
        var weekly = ReminderPolicy()
        _ = weekly.observe(remaining: 100, resetAt: 200, windowMinutes: 10080, fresh: true, now: 100)
        check(weekly.tick(now: 200).isEmpty, "Weekly window is not a 5-hour reset")
        print("Passed \(checks) reminder checks")
    }
}
