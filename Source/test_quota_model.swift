import Foundation
@main struct QuotaModelTests {
 static func main() {
  var checks = 0
  func check(_ ok: Bool, _ message: String) { precondition(ok, message); checks += 1 }
  let short = QuotaWindow(usedPercent: 20, windowDurationMins: 300, resetsAt: 200)
  let week = QuotaWindow(usedPercent: 79, windowDurationMins: 10080, resetsAt: 500)
  func usage(_ plan: String?, _ p: QuotaWindow?, _ s: QuotaWindow?) -> Usage {
   Usage(primary: p, secondary: s, resetCount: nil, plan: plan, allowed: true)
  }
  let pro = usage("prolite", week, nil)
  check(pro.planTitle == "Pro", "Real prolite account identifies as Pro")
  check(pro.windows.count == 1 && pro.otherWindow == nil, "No invented second window")
  check(pro.mainWindow?.remaining == 21, "No plan multiplier on authoritative percentages")
  check(pro.mainWindow?.label == "每周剩余", "A weekly primary is labeled weekly")
  check(pro.mainWindow?.period == "7 天", "Duration comes from response")
  let plus = usage("plus", short, week)
  check(plus.windows.count == 2 && plus.planTitle == "Plus", "Plus retains both windows")
  check(plus.mainWindow?.windowDurationMins == 300, "Shortest real window takes priority")
  check(plus.otherWindow?.windowDurationMins == 10080, "Long window follows")
  check(usage("pro", short, week).windows.count == 2, "Plan name never overrides server windows")
  check(usage("pro", nil, week).mainWindow?.remaining == 21, "Secondary-only data is usable in status and reminders")
  check(usage("plus", week, short).mainWindow?.windowDurationMins == 300, "Reordered API slots preserve meaning")
  check(usage(nil,nil,nil).planTitle == "套餐未知", "Never assume a plan")
  check(usage("future-plan",nil,nil).planTitle == "future-plan", "Unknown plan is retained")
  check(usage("pro",nil,nil).windows.isEmpty, "Missing quota never becomes unlimited or 100 percent")
  let invalid = QuotaWindow(usedPercent: .nan, windowDurationMins: 300, resetsAt: nil)
  check(usage("pro",invalid,week).mainWindow?.windowDurationMins == 10080, "Invalid numbers do not replace valid data")
  print("Passed \(checks) plan/window adaptation checks")
 }
}
