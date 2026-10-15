import AppKit
import SwiftUI
import Combine

struct QuotaWindow: Decodable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Double?
    var remaining: Double { max(0, min(100, 100 - usedPercent)) }
    var percent: String { "\(Int(remaining.rounded()))%" }
    var resetDate: Date? { resetsAt.map(Date.init(timeIntervalSince1970:)) }
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
}

struct LocalTaskState: Decodable {
    let count: Int?
    let state: String
    let detail: String
    static let initial = LocalTaskState(count: nil, state: "loading", detail: "正在读取本机任务状态…")
    var title: String {
        guard let count = count else { return state == "loading" ? "正在连接…" : "任务状态未知" }
        return count > 0 ? "本机运行 · \(count) 个任务" : "本机空闲 · 0 个任务"
    }
}

struct Snapshot: Decodable {
    let usage: Usage?
    let usageUpdatedAt: Double?
    let usageState: String
    let usageMessage: String
    let tasks: LocalTaskState
    static let initial = Snapshot(usage: nil, usageUpdatedAt: nil, usageState: "loading", usageMessage: "正在连接 Codex…", tasks: .initial)
}

enum SystemSoundLibrary {
    static let directory = URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true)
    static let files: [String: URL] = {
        let extensions: Set<String> = ["aiff", "aif", "wav", "caf"]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return Dictionary(urls.filter { extensions.contains($0.pathExtension.lowercased()) }
            .map { ($0.deletingPathExtension().lastPathComponent, $0) }, uniquingKeysWith: { first, _ in first })
    }()
    static var names: [String] { files.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    static func selected(_ key: String, fallback: String) -> String {
        let saved = UserDefaults.standard.string(forKey: key) ?? fallback
        return files[saved] != nil ? saved : (files[fallback] != nil ? fallback : names.first ?? "")
    }
}

final class Telemetry: ObservableObject {
    let weather = WeatherController()
    @Published var snapshot = Snapshot.initial
    @Published var now = Date()
    private var bridge: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var buffer = Data()
    private var clock: Timer?
    private var restart: Timer?
    private var stopped = false
    private var lastRefresh = Date.distantPast
    private var reminders = ReminderPolicy()
    private var savedReminderHistory = ReminderHistory()
    private var activeSound: NSSound?
    @Published var soundEnabled = (UserDefaults.standard.object(forKey: "soundAlertsEnabled") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(soundEnabled, forKey: "soundAlertsEnabled") }
    }
    @Published var lowUsageSound = SystemSoundLibrary.selected("lowUsageSound", fallback: "Basso") {
        didSet { UserDefaults.standard.set(lowUsageSound, forKey: "lowUsageSound") }
    }
    @Published var resetSound = SystemSoundLibrary.selected("resetSound", fallback: "Hero") {
        didSet { UserDefaults.standard.set(resetSound, forKey: "resetSound") }
    }
    @Published var backgroundTransparency: Double = {
        let value = (UserDefaults.standard.object(forKey: "backgroundTransparency") as? NSNumber)?.doubleValue ?? 0.5
        return value.isFinite ? max(0, min(1, value)) : 0.5
    }() {
        didSet {
            if !CommandLine.arguments.contains("--render-preview") {
                UserDefaults.standard.set(backgroundTransparency, forKey: "backgroundTransparency")
            }
        }
    }
    @Published var weatherEnabled = (UserDefaults.standard.object(forKey: "weatherEnabled") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(weatherEnabled, forKey: "weatherEnabled")
            if weatherEnabled { weather.start() } else { weather.stop() }
        }
    }
    @Published var codexRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").isEmpty
    @Published var desktopFloating = false
    var toggleFloating: (() -> Void)?
    var showSoundSelector: ((ReminderEvent) -> Void)?
    var showSettings: (() -> Void)?
    var showCodexActions: (() -> Void)?
    var onUpdate: (() -> Void)?

    func start() {
        if weatherEnabled && !CommandLine.arguments.contains("--smoke-test") { weather.start() }
        if let data = UserDefaults.standard.data(forKey: "soundReminderHistory"),
           let history = try? JSONDecoder().decode(ReminderHistory.self, from: data) {
            reminders.history = history
            savedReminderHistory = history
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.now = Date()
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").contains { !$0.isTerminated }
            if self.codexRunning != running { self.codexRunning = running }
            self.deliverReminders(self.reminders.tick(now: self.now.timeIntervalSince1970))
        }
        clock = timer
        RunLoop.main.add(timer, forMode: .common)
        launchBridge()
    }

    private func launchBridge() {
        guard !stopped else { return }
        guard let script = Bundle.main.url(forResource: "monitor", withExtension: "py") else {
            fail("监测组件缺失，请重新构建应用。")
            return
        }
        let process = Process()
        let inPipe = Pipe(), outPipe = Pipe()
        let pythonCandidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3",
            "/Library/Developer/CommandLineTools/usr/bin/python3",
            "/Applications/Xcode.app/Contents/Developer/usr/bin/python3"]
        guard let python = pythonCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            fail("未找到 Python 3。安装 Python 3 后重新打开看板。")
            return
        }
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-u", script.path]
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        bridge = process
        input = inPipe
        output = outPipe
        buffer.removeAll()
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self = self, self.bridge === process else { return }
                self.buffer.append(chunk)
                while let newline = self.buffer.firstIndex(of: 10) {
                    let line = Data(self.buffer[..<newline])
                    self.buffer.removeSubrange(...newline)
                    if let snapshot = try? JSONDecoder().decode(Snapshot.self, from: line) {
                        self.snapshot = snapshot
                        let window = snapshot.usage?.primary
                        let remaining = window.flatMap { $0.usedPercent.isFinite && $0.usedPercent >= 0 && $0.usedPercent <= 100 ? $0.remaining : nil }
                        let events = self.reminders.observe(remaining: remaining, resetAt: window?.resetsAt,
                                                            windowMinutes: window?.windowDurationMins,
                                                            fresh: snapshot.usageState == "live",
                                                            now: Date().timeIntervalSince1970)
                        self.deliverReminders(events)
                        self.onUpdate?()
                    }
                }
            }
        }
        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self = self, !self.stopped, self.bridge === finished else { return }
                self.fail("监测连接已断开，正在自动重连。")
                self.output?.fileHandleForReading.readabilityHandler = nil
                self.restart?.invalidate()
                self.restart = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
                    self?.launchBridge()
                }
            }
        }
        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            fail("无法启动监测组件。请确认本机 Command Line Tools 的 Python 3 可用。")
        }
    }

    private func deliverReminders(_ events: [ReminderEvent]) {
        guard !CommandLine.arguments.contains("--smoke-test") else { return }
        // Persist only changed history; routine timer ticks never write preferences.
        if reminders.history != savedReminderHistory, let data = try? JSONEncoder().encode(reminders.history) {
            UserDefaults.standard.set(data, forKey: "soundReminderHistory")
            savedReminderHistory = reminders.history
        }
        guard soundEnabled else { return }
        for (index, event) in events.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 1.2) { [weak self] in
                guard let self = self, self.soundEnabled else { return }
                self.playReminder(event)
            }
        }
    }

    private func playReminder(_ event: ReminderEvent) {
        let name = event == .lowUsage ? lowUsageSound : resetSound
        guard let url = SystemSoundLibrary.files[name], let sound = NSSound(contentsOf: url, byReference: true) else {
            NSSound.beep()
            return
        }
        activeSound?.stop()
        activeSound = sound
        sound.volume = 1
        if !sound.play() { NSSound.beep() }
    }

    func closeCodexApplication() {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
            .filter { !$0.isTerminated }.forEach { $0.terminate() }
    }

    func selectReminderSound(_ name: String, for event: ReminderEvent) {
        guard SystemSoundLibrary.files[name] != nil else { return }
        if event == .lowUsage { lowUsageSound = name }
        else { resetSound = name }
        // Explicit selection always previews, including clicking the current choice again.
        playReminder(event)
    }

    private func fail(_ message: String) {
        let failed = Snapshot(usage: snapshot.usage, usageUpdatedAt: snapshot.usageUpdatedAt,
                            usageState: snapshot.usage == nil ? "unavailable" : "stale", usageMessage: message,
                            tasks: LocalTaskState(count: nil, state: "unknown", detail: "监测连接不可用。"))

        snapshot = failed
        onUpdate?()
    }

    func refresh() {
        guard Date().timeIntervalSince(lastRefresh) >= 2 else { return }
        lastRefresh = Date()
        if let bridge = bridge, bridge.isRunning {
            do { try input?.fileHandleForWriting.write(contentsOf: Data("refresh\n".utf8)) }
            catch { fail("刷新失败，正在重连。") }
        } else {
            restart?.invalidate()
            launchBridge()
        }
    }

    func stop() {
        stopped = true
        clock?.invalidate()
        restart?.invalidate()
        output?.fileHandleForReading.readabilityHandler = nil
        activeSound?.stop()
        weather.stop()
        // Closing stdin lets the bridge terminate and reap its own app-server child.
        try? input?.fileHandleForWriting.close()
    }
}

private enum Palette {
    static let secondary = Color(red: 0.80, green: 0.83, blue: 0.87)
    static let green = Color(red: 0.32, green: 0.88, blue: 0.48)
    static let amber = Color(red: 1, green: 0.75, blue: 0.32)
    static let line = Color.white.opacity(0.12)
}

struct QuotaBar: View {
    let window: QuotaWindow?
    let stale: Bool
    var height: CGFloat = 6
    private var tint: Color {
        guard !stale, let remaining = window?.remaining else { return Palette.secondary }
        return remaining <= 10 ? .red : remaining <= 25 ? Palette.amber : Palette.green
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(tint).frame(width: geometry.size.width * (window?.remaining ?? 0) / 100)
            }
        }
        .frame(height: height)
        .accessibilityLabel("剩余用量")
        .accessibilityValue(window?.percent ?? "暂无数据")
    }
}

struct HeaderDragHandle: NSViewRepresentable {
    let enabled: Bool
    final class DragView: NSView {
        var enabled = false
        override func hitTest(_ point: NSPoint) -> NSView? { enabled ? super.hitTest(point) : nil }
        override func mouseDown(with event: NSEvent) {
            if enabled { window?.performDrag(with: event) }
        }
    }
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) { view.enabled = enabled }
}

/// Blur the whole backdrop consistently; transparent icon holes never need a tile.
struct FrostedPanelBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 16
        view.layer?.masksToBounds = true
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// All surfaces share the same live weather palette, material and tint strength.
struct PanelBackdrop: View {
    @ObservedObject var model: Telemetry
    @ObservedObject private var weather: WeatherController
    var showsWeatherIcon = false
    init(model: Telemetry, showsWeatherIcon: Bool = false) {
        self.model = model; self.weather = model.weather; self.showsWeatherIcon = showsWeatherIcon
    }
    var body: some View {
        ZStack {
            if model.backgroundTransparency > 0 { FrostedPanelBackdrop() }
            if model.weatherEnabled {
                if model.backgroundTransparency >= 0.5 {
                    Color(red: 0.145, green: 0.16, blue: 0.19).opacity(1 - model.backgroundTransparency)
                } else {
                    WeatherBackdrop(reading: weather.reading, now: model.now, opacity: 1 - model.backgroundTransparency, showsArtwork: showsWeatherIcon)
                }
                if showsWeatherIcon {
                    VStack {
                        HStack {
                            Spacer()
                            WeatherBadge(reading: weather.reading, now: model.now)
                                .padding(.top, 32).padding(.trailing, 5)
                        }
                        Spacer()
                    }
                }
            } else {
                Color(red: 0.08, green: 0.12, blue: 0.17).opacity(1 - model.backgroundTransparency)
            }
        }.allowsHitTesting(false)
    }
}

struct Dashboard: View {
    @ObservedObject var model: Telemetry
    @ObservedObject private var weather: WeatherController
    init(model: Telemetry) { self.model = model; self.weather = model.weather }
    private var snapshot: Snapshot { model.snapshot }
    private var stale: Bool { snapshot.usageState != "live" }
    private var statusColor: Color {
        if snapshot.tasks.count == nil { return Palette.amber }
        return (snapshot.tasks.count ?? 0) > 0 ? Palette.green : Palette.secondary
    }
    private func resetTime(_ window: QuotaWindow?) -> String {
        guard let date = window?.resetDate else { return "暂无数据" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone.current
        if Calendar.current.isDateInToday(date) { formatter.dateFormat = "'今天' HH:mm" }
        else if Calendar.current.isDateInTomorrow(date) { formatter.dateFormat = "'明天' HH:mm" }
        else { formatter.dateFormat = "M月d日 HH:mm" }
        return formatter.string(from: date)
    }
    private var countdown: String {
        guard let date = snapshot.usage?.primary?.resetDate else { return "--:--:--" }
        let seconds = Int(date.timeIntervalSince(model.now))
        if seconds <= 0 { return "等待更新" }
        let days = seconds / 86400
        let value = String(format: "%02d:%02d:%02d", (seconds % 86400) / 3600, (seconds % 3600) / 60, seconds % 60)
        return days > 0 ? "\(days)天 \(value)" : value
    }
    private var updated: String {
        guard let timestamp = snapshot.usageUpdatedAt else { return "连接中" }
        let elapsed = max(0, Int(model.now.timeIntervalSince1970 - timestamp))
        if stale { return "上次数据" }
        return elapsed < 5 ? "刚刚更新" : "\(elapsed) 秒前更新"
    }

    private var currentDate: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "M月d日"
        return formatter.string(from: model.now)
    }

    private var weatherTitle: String {
        guard model.weatherEnabled else { return "天气已关闭" }
        guard let reading = weather.reading else { return weather.message }
        return "\(weather.place) \(Int(reading.temperature.rounded()))°C"
    }
    private var weatherDetail: String {
        guard model.weatherEnabled, let reading = weather.reading else { return weatherTitle }
        return [weatherTitle, reading.kind.title, weather.message].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                HStack(spacing: 5) {
                    Text(model.now.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))).font(.system(size: 16, weight: .medium, design: .rounded)).monospacedDigit()
                    VStack(alignment: .leading, spacing: 0) {
                        Text(currentDate)
                        Text(model.now.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).weekday(.abbreviated))).foregroundColor(Palette.secondary)
                    }.font(.system(size: 8)).lineLimit(1)
                }.frame(height: 20).overlay(HeaderDragHandle(enabled: model.desktopFloating))
                Spacer(minLength: 6)
                HStack(spacing: 4) {
                    Image(systemName: snapshot.tasks.count == nil ? "questionmark" : (snapshot.tasks.count ?? 0) > 0 ? "waveform.path" : "pause")
                        .font(.system(size: 10, weight: .medium)).accessibilityHidden(true)
                    Text(snapshot.tasks.count.map { $0 > 99 ? "99+" : String($0) } ?? "—")
                        .font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit()
                }
                .foregroundColor(statusColor)
                .padding(.horizontal, 7).frame(height: 19)
                .background(statusColor.opacity(0.13), in: Capsule())
                .overlay(Capsule().strokeBorder(statusColor.opacity(0.16), lineWidth: 0.5))
                .help(snapshot.tasks.title).accessibilityLabel(snapshot.tasks.title)
                Button { model.showSettings?() } label: {
                    Image(systemName: "gearshape").font(.system(size: 11)).frame(width: 20, height: 20)
                }.buttonStyle(.borderless).help("设置").accessibilityLabel("设置")
                Button { model.showCodexActions?() } label: {
                    HStack(spacing: 1) {
                        Image(systemName: "arrow.up.forward.app").font(.system(size: 11))
                        Image(systemName: "chevron.down").font(.system(size: 6, weight: .semibold))
                    }.frame(width: 24, height: 20)
                }.buttonStyle(.borderless).help("打开或退出 Codex").accessibilityLabel("Codex 操作菜单")
                Button { model.toggleFloating?() } label: {
                    Image(systemName: model.desktopFloating ? "pin.fill" : "pin")
                        .font(.system(size: 12, weight: .medium)).frame(width: 20, height: 20)
                        .foregroundColor(model.desktopFloating ? Palette.green : .white)
                }.buttonStyle(.borderless)
                 .help(model.desktopFloating ? "返回菜单栏" : "固定到桌面；拖动标题可移动")
                 .accessibilityLabel(model.desktopFloating ? "返回菜单栏" : "固定到桌面")
            }.padding(.bottom, 6)

            Group {
                HStack(alignment: .center, spacing: 10) {
                    Text(snapshot.usage?.primary?.percent ?? "--%")
                        .font(.system(size: 36, weight: .semibold, design: .rounded)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.85)
                        .foregroundColor(stale ? Palette.secondary : .white)
                        .frame(width: 88, alignment: .leading)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("重置").foregroundColor(Palette.secondary)
                            Text(countdown).fontWeight(.semibold).monospacedDigit()
                        }.font(.system(size: 11)).lineLimit(1).minimumScaleFactor(0.8)
                        Text(snapshot.usage?.primary?.label ?? "剩余用量")
                            .font(.system(size: 11)).foregroundColor(Palette.secondary)
                            .lineLimit(1).minimumScaleFactor(0.75)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 42)
                }.frame(height: 44).padding(.bottom, 6)
                QuotaBar(window: snapshot.usage?.primary, stale: stale).padding(.bottom, 10)
                HStack {
                    Text(snapshot.usage?.secondary?.label ?? "每周剩余").font(.system(size: 11))
                    Spacer()
                    Text(snapshot.usage?.secondary?.percent ?? "--%")
                        .font(.system(size: 13, weight: .medium)).monospacedDigit()
                }.padding(.bottom, 6)
                QuotaBar(window: snapshot.usage?.secondary, stale: stale, height: 4).padding(.bottom, 10)
            }
            Rectangle().fill(Palette.line).frame(height: 1).padding(.bottom, 6)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("可用重置").foregroundColor(Palette.secondary)
                    Spacer()
                    Text(snapshot.usage?.resetCount.map { "\($0) 次" } ?? "—")
                        .fontWeight(.semibold).monospacedDigit()
                }
                HStack {
                    Text("短期重置").foregroundColor(Palette.secondary)
                    Spacer()
                    Text(resetTime(snapshot.usage?.primary)).monospacedDigit()
                }
                HStack {
                    Text("每周重置").foregroundColor(Palette.secondary)
                    Spacer()
                    Text(resetTime(snapshot.usage?.secondary)).monospacedDigit()
                }
            }.font(.system(size: 11)).padding(.bottom, 6)


            if !snapshot.usageMessage.isEmpty {
                Text(snapshot.usageMessage).font(.system(size: 11)).foregroundColor(Palette.amber)
                    .fixedSize(horizontal: false, vertical: true).padding(.bottom, 6)
            } else if snapshot.usage?.allowed == false {
                Text("当前账户暂不可使用常规额度")
                    .font(.system(size: 11)).foregroundColor(Palette.amber).padding(.bottom, 6)
            }
            HStack(spacing: 4) {
                Image(systemName: model.weatherEnabled ? "location.fill" : "location.slash").font(.system(size: 9)).foregroundColor(Palette.secondary)
                Text(weatherTitle).font(.system(size: 11, weight: .medium))
                    .lineLimit(1).minimumScaleFactor(0.8).help(weatherDetail)
                Spacer()
                Circle().fill(stale ? Palette.amber : Palette.green).frame(width: 4, height: 4).accessibilityHidden(true)
                Text(updated).font(.system(size: 9)).foregroundColor(Palette.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8).help(snapshot.usageMessage.isEmpty ? updated : snapshot.usageMessage)
                Button { model.refresh() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11)).frame(width: 20, height: 18)
                }.buttonStyle(.borderless).accessibilityLabel("刷新用量与任务状态").keyboardShortcut("r", modifiers: .command)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .frame(width: 270).frame(minHeight: 227)
        .foregroundColor(.white)
        .background { PanelBackdrop(model: model, showsWeatherIcon: true) }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
        .preferredColorScheme(.dark)
    }
}

struct SoundSelector: View {
    @ObservedObject var model: Telemetry
    let event: ReminderEvent
    let onDone: () -> Void
    var doneTitle: String = "完成"
    var embedded = false
    private var selection: String { event == .lowUsage ? model.lowUsageSound : model.resetSound }
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(event == .lowUsage ? "低用量提示音" : "重置提示音").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(doneTitle, action: onDone).buttonStyle(.borderless)
            }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(SystemSoundLibrary.names, id: \.self) { name in
                        Button { model.selectReminderSound(name, for: event) } label: {
                            HStack {
                                Text(name)
                                Spacer()
                                if selection == name { Image(systemName: "checkmark").foregroundColor(Palette.green) }
                            }
                            .font(.system(size: 11)).padding(.horizontal, 8).padding(.vertical, 6)
                            .contentShape(Rectangle())
                            .background(selection == name ? Color.white.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain).accessibilityValue(selection == name ? "已选择" : "")
                    }
                }
            }.frame(height: 176)
            Text("点击即播放并保存，可连续切换").font(.system(size: 10)).foregroundColor(Palette.secondary)
        }
        .padding(12).frame(width: 270).foregroundColor(.white)
        .background { if !embedded { PanelBackdrop(model: model) } }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { if !embedded { RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.16), lineWidth: 1) } }
        .preferredColorScheme(.dark)
    }
}

struct SettingsView: View {
    @ObservedObject var model: Telemetry
    @ObservedObject private var weather: WeatherController
    @State private var showingAbout = false
    @State private var soundSelection: ReminderEvent?
    let onDone: () -> Void
    init(model: Telemetry, onDone: @escaping () -> Void) {
        self.model = model; self.weather = model.weather; self.onDone = onDone
    }
    var body: some View {
        Group {
            if showingAbout {
                AboutView(model: model, onDone: { showingAbout = false }, embedded: true)
            } else if let event = soundSelection {
                SoundSelector(model: model, event: event, onDone: { soundSelection = nil }, doneTitle: "返回设置", embedded: true)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("设置").font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Button("完成", action: onDone).buttonStyle(.borderless)
                    }
                    Group {
                        Toggle("声音提醒", isOn: $model.soundEnabled).toggleStyle(.switch)
                        soundRow("低用量提示音", name: model.lowUsageSound, event: .lowUsage)
                        soundRow("重置提示音", name: model.resetSound, event: .resetDue)
                        Divider()
                    }
                    Group {
                        Toggle("天气背景", isOn: $model.weatherEnabled).toggleStyle(.switch)
                        HStack {
                            Text("定位权限").foregroundColor(Palette.secondary)
                            Text(weather.authorizationMessage).lineLimit(1)
                            Spacer()
                            Button("设置") { weather.openLocationSettings() }
                        }
                        HStack {
                            Button("更新天气") { weather.refresh() }.disabled(!model.weatherEnabled)
                            Spacer()
                            Link("Open-Meteo", destination: URL(string: "https://open-meteo.com/")!)
                        }
                        Divider()
                    }
                    VStack(spacing: 8) {
                        HStack {
                            Text("背景通透度")
                            Spacer()
                            Text("\(Int((model.backgroundTransparency * 100).rounded()))%").monospacedDigit()
                        }
                        Slider(value: $model.backgroundTransparency, in: 0...1)
                            .accessibilityLabel("背景通透度")
                        Text("图标随天气与昼夜切换，透明度不改变图标。\n50% 及以上为简洁背景，低于 50% 为天气背景。\n所有页面共享毛玻璃及背景颜色。")
                            .font(.system(size: 10)).foregroundColor(Palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Divider()
                    HStack {
                        Button("关于") { showingAbout = true }
                        Spacer()
                        Button("退出看板") { NSApplication.shared.terminate(nil) }
                    }
                }.font(.system(size: 11)).padding(12).frame(width: 270)
            }
        }
        .buttonStyle(.borderless)
        .tint(Palette.green)
        .foregroundColor(.white)
        .background { PanelBackdrop(model: model) }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
        .preferredColorScheme(.dark)
    }
    private func soundRow(_ title: String, name: String, event: ReminderEvent) -> some View {
        Button { soundSelection = event } label: {
            HStack {
                Text(title)
                Spacer()
                Text(name).foregroundColor(Palette.secondary)
                Image(systemName: "chevron.right").font(.system(size: 10))
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

func openCodex() {
    let candidates = ["/Applications/Codex.app", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Codex.app").path]
    if let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration())
    }
}

struct AboutView: View {
    @ObservedObject var model: Telemetry
    let onDone: () -> Void
    var embedded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("关于").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("返回", action: onDone)
            }
            HStack {
                Text("axbro").font(.system(size: 18, weight: .semibold))
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "").foregroundColor(Palette.secondary)
                Spacer()
                Circle().fill(model.codexRunning ? Palette.green : Palette.secondary).frame(width: 5, height: 5)
                Text(model.codexRunning ? "Codex 已运行" : "Codex 未运行").font(.system(size: 10))
            }
            Divider()
            aboutText("本机监测", "仅支持 Codex，每 5 秒刷新用量与任务状态，随 Codex 启动和退出。")
            aboutText("声音提醒", "剩余用量低于 5%、5 小时额度重置时提醒。点击系统提示音即可播放并保存。")
            aboutText("任务统计", "仅统计当前用户本机日志，等待输入可能计入。运行不代表持续消耗；不含云端、其他设备及内部子代理。")
            aboutText("数据与环境", "仅使用安装者本机数据，不附带他人账号或聊天记录。需要已登录的 Codex 与 Python 3。")
        }.font(.system(size: 11)).padding(12).frame(width: 270)
        .buttonStyle(.borderless).tint(Palette.green).foregroundColor(.white)
        .background { if !embedded { PanelBackdrop(model: model) } }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { if !embedded { RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.16), lineWidth: 1) } }
        .preferredColorScheme(.dark)
    }
    private func aboutText(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).fontWeight(.medium)
            Text(body).font(.system(size: 10)).foregroundColor(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
        }
    }
}

final class DashboardPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = Telemetry()
    private var statusItem: NSStatusItem?
    private var statusAppearanceObserver: StatusQuotaAppearanceObserver?
    private var panel: DashboardPanel?
    private var previewWindow: NSWindow?
    private var soundPopover: NSPopover?
    private var settingsPopover: NSPopover?
    private var restoringPlacement = false
    private var isTesting: Bool { CommandLine.arguments.contains("--smoke-test") }
    private var smokeStarted = false
    private var smokeTimeout: Timer?
    private var hoverDelay: Timer?
    private var hoverWatch: Timer?
    private var dismissDelay: Timer?
    private var isPinned = false
    private var globalClick: Any?
    private var localClick: Any?
    private var tracking: NSTrackingArea?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let index = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.count > index + 2 {
            renderPreview(inputPath: CommandLine.arguments[index + 1], outputPath: CommandLine.arguments[index + 2])
            return
        }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "local.dean.CodexMini")
        if others.contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApplication.shared.terminate(nil)
            return
        }
        let item = NSStatusBar.system.statusItem(withLength: StatusQuotaIndicator.itemLength)
        statusItem = item
        if let button = item.button {
            button.title = ""
            button.imagePosition = .imageOnly
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            button.target = self
            button.action = #selector(togglePanel)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Codex 剩余用量；悬停或点击展开看板")
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
            button.addTrackingArea(area)
            tracking = area
            let appearanceObserver = StatusQuotaAppearanceObserver(frame: .zero)
            appearanceObserver.setAccessibilityElement(false)
            appearanceObserver.onChange = { [weak self] in self?.updateStatus() }
            button.addSubview(appearanceObserver)
            statusAppearanceObserver = appearanceObserver
        }
        updateStatus()
        let host = NSHostingView(rootView: Dashboard(model: model))
        let window = DashboardPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .statusBar
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = host
        window.delegate = self
        window.onEscape = { [weak self] in
            guard let self = self, !self.model.desktopFloating else { return }
            self.hidePanel()
        }
        model.toggleFloating = { [weak self] in self?.toggleDesktopFloating() }
        model.showSettings = { [weak self] in self?.presentSettings() }
        model.showCodexActions = { [weak self] in self?.presentCodexActions() }
        model.showSoundSelector = { [weak self] event in
            // Wait until the native parent menu has finished its click handling.
            DispatchQueue.main.async { self?.presentSoundSelector(event) }
        }
        panel = window
        model.onUpdate = { [weak self] in
            self?.updateStatus()
            self?.resizePanel()
            self?.checkSmokeTest()
        }
        if CommandLine.arguments.contains("--smoke-test") {
            smokeTimeout = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { [weak self] _ in
                self?.writeSmokeResult(["passed": false, "error": "Timed out waiting for live data"])
            }
        }
        globalClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismissTransientPanel()
        }
        localClick = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self else { return event }
            if event.window !== self.panel && event.window !== self.statusItem?.button?.window &&
                event.window !== self.soundPopover?.contentViewController?.view.window &&
                event.window !== self.settingsPopover?.contentViewController?.view.window {
                self.dismissTransientPanel()
            }
            return event
        }
        if !isTesting && UserDefaults.standard.bool(forKey: "desktopFloatingEnabled") {
            restoreDesktopWindow()
        }
        model.start()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wokeUp), name: NSWorkspace.didWakeNotification, object: nil)
    }

    func updateStatus() {
        guard let button = statusItem?.button else { return }
        let snapshot = model.snapshot
        let indicator = StatusQuotaIndicator(remaining: snapshot.usage?.primary?.remaining,
                                             isStale: snapshot.usageState != "live")
        button.image = indicator.image(for: button)
        button.needsDisplay = true
        let freshness = indicator.showsStaleMarker ? "，上次数据" : ""
        let label = snapshot.usage?.primary?.label ?? "剩余用量"
        button.toolTip = "axbro · \(label)：\(indicator.percentText)\(freshness)\n\(snapshot.tasks.title)\n悬停或点击展开看板"
        button.setAccessibilityValue("Codex，剩余用量 \(indicator.percentText)\(freshness)，\(snapshot.tasks.title)")
    }

    private var buttonFrame: NSRect? {
        guard let button = statusItem?.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func resizePanel() {
        guard let panel = panel, let view = panel.contentView else { return }
        let size = view.fittingSize
        let previousTop = panel.frame.maxY
        if size.width > 0 && size.height > 0 {
            panel.setContentSize(size)
            if model.desktopFloating {
                panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: previousTop - panel.frame.height))
            }
        }
        if panel.isVisible && !model.desktopFloating { positionPanel() }
    }

    private func positionPanel() {
        guard !model.desktopFloating, let panel = panel, let anchor = buttonFrame,
              let screen = statusItem?.button?.window?.screen ?? NSScreen.main else { return }
        let x = max(screen.visibleFrame.minX + 8, min(anchor.midX - panel.frame.width / 2, screen.visibleFrame.maxX - panel.frame.width - 8))
        panel.setFrameOrigin(NSPoint(x: x, y: anchor.minY - panel.frame.height - 4))
    }

    private func showPanel(pinned: Bool) {
        if model.desktopFloating { panel?.orderFrontRegardless(); return }
        hoverDelay?.invalidate()
        dismissDelay?.invalidate()
        isPinned = pinned
        resizePanel()
        positionPanel()
        if pinned { panel?.makeKeyAndOrderFront(nil) }
        else { panel?.orderFrontRegardless() }
        // Passive hover must not activate another app or interrupt keyboard focus.
        if !pinned { startHoverWatch() } else { hoverWatch?.invalidate() }
        model.refresh()
    }

    private func dismissTransientPanel() {
        settingsPopover?.performClose(nil)
        soundPopover?.performClose(nil)
        if !model.desktopFloating { hidePanel() }
    }

    private func makeCodexMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let open = menu.addItem(withTitle: "打开 Codex", action: #selector(openMainApp), keyEquivalent: "")
        open.target = self
        menu.addItem(.separator())
        let close = menu.addItem(withTitle: "退出 Codex", action: #selector(closeMainApp), keyEquivalent: "")
        close.target = self
        close.isEnabled = model.codexRunning
        return menu
    }

    private func presentCodexActions() {
        // Pin a hover-open panel while its native menu tracks the pointer.
        showPanel(pinned: true)
        guard let view = panel?.contentView else { return }
        let point = NSPoint(x: view.bounds.maxX - 56, y: view.isFlipped ? 28 : view.bounds.maxY - 28)
        makeCodexMenu().popUp(positioning: nil, at: point, in: view)
    }

    private func presentSettings() {
        if !isTesting { NSApplication.shared.activate(ignoringOtherApps: true) }
        if settingsPopover?.isShown == true { settingsPopover?.performClose(nil); return }
        showPanel(pinned: true)
        guard let view = panel?.contentView else { return }
        soundPopover?.performClose(nil)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = NSHostingController(rootView: SettingsView(model: model, onDone: { [weak self] in
            self?.settingsPopover?.performClose(nil)
        }))
        settingsPopover = popover
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxX)
    }

    private func presentSoundSelector(_ event: ReminderEvent) {
        showPanel(pinned: true)
        guard let view = panel?.contentView else { return }
        soundPopover?.performClose(nil)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = NSHostingController(rootView: SoundSelector(model: model, event: event, onDone: { [weak self] in
            self?.soundPopover?.performClose(nil)
        }))
        soundPopover = popover
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxX)
    }

    private func storedPlacement() -> FloatingPlacement? {
        guard let data = UserDefaults.standard.data(forKey: "desktopFloatingPlacement") else { return nil }
        return try? JSONDecoder().decode(FloatingPlacement.self, from: data)
    }

    private func saveDesktopPlacement() {
        guard !isTesting, !restoringPlacement, model.desktopFloating, let panel = panel else { return }
        let placement = FloatingPlacement(x: panel.frame.minX, top: panel.frame.maxY)
        if let data = try? JSONEncoder().encode(placement) {
            UserDefaults.standard.set(data, forKey: "desktopFloatingPlacement")
        }
    }

    func windowDidMove(_ notification: Notification) { saveDesktopPlacement() }

    private func restoreDesktopWindow() {
        guard let panel = panel else { return }
        restoringPlacement = true
        positionPanel()
        model.desktopFloating = true
        isPinned = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        if let origin = storedPlacement()?.origin(size: panel.frame.size, screens: NSScreen.screens.map(\.visibleFrame)) {
            panel.setFrameOrigin(origin)
        }
        panel.orderFrontRegardless()
        restoringPlacement = false
        saveDesktopPlacement()
    }

    private func toggleDesktopFloating() {
        guard let panel = panel else { return }
        hoverDelay?.invalidate()
        dismissDelay?.invalidate()
        hoverWatch?.invalidate()
        model.desktopFloating.toggle()
        if !isTesting { UserDefaults.standard.set(model.desktopFloating, forKey: "desktopFloatingEnabled") }
        panel.isMovableByWindowBackground = model.desktopFloating
        if model.desktopFloating {
            isPinned = true
            panel.level = .floating
            if let origin = storedPlacement()?.origin(size: panel.frame.size, screens: NSScreen.screens.map(\.visibleFrame)) {
                panel.setFrameOrigin(origin)
            } else {
                panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: panel.frame.minY - 28))
            }
            panel.orderFrontRegardless()
            saveDesktopPlacement()
        } else {
            panel.level = .statusBar
            showPanel(pinned: true)
        }
    }

    private func hidePanel() {
        hoverDelay?.invalidate()
        dismissDelay?.invalidate()
        hoverWatch?.invalidate()
        isPinned = false
        panel?.orderOut(nil)
    }

    @objc(mouseEntered:) func mouseEntered(with event: NSEvent) {
        guard panel?.isVisible != true else { return }
        hoverDelay?.invalidate()
        hoverDelay = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            guard let self = self, self.buttonFrame?.contains(NSEvent.mouseLocation) == true else { return }
            self.showPanel(pinned: false)
        }
    }

    @objc(mouseExited:) func mouseExited(with event: NSEvent) { hoverDelay?.invalidate() }

    private func startHoverWatch() {
        hoverWatch?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let panel = self.panel, panel.isVisible, !self.isPinned, !self.model.desktopFloating else { return }
            let point = NSEvent.mouseLocation
            let inside = panel.frame.insetBy(dx: -4, dy: -8).contains(point) ||
                (self.buttonFrame?.insetBy(dx: -4, dy: -8).contains(point) ?? false)
            if inside {
                self.dismissDelay?.invalidate()
                self.dismissDelay = nil
            } else if self.dismissDelay == nil {
                self.dismissDelay = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                    self?.hidePanel()
                }
            }
        }
        hoverWatch = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc func wokeUp() { model.refresh() }

    @objc func togglePanel() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            dismissTransientPanel()
            guard let button = statusItem?.button else { return }
            let menu = NSMenu()
            menu.addItem(withTitle: "打开 Codex", action: #selector(openMainApp), keyEquivalent: "")
            menu.addItem(withTitle: "刷新", action: #selector(refreshData), keyEquivalent: "r")
            menu.addItem(.separator())
            menu.addItem(withTitle: "退出 axbro", action: #selector(quit), keyEquivalent: "q")
            menu.items.forEach { $0.target = self }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
            return
        }
        if model.desktopFloating { panel?.orderFrontRegardless(); return }
        if panel?.isVisible == true && isPinned { hidePanel() }
        else { showPanel(pinned: true) }
    }
    @objc func openMainApp() { openCodex() }
    @objc func closeMainApp() { model.closeCodexApplication() }
    @objc func refreshData() { model.refresh() }
    @objc func quit() { NSApplication.shared.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        saveDesktopPlacement()
        if !isTesting { UserDefaults.standard.synchronize() }
        soundPopover?.performClose(nil)
        settingsPopover?.performClose(nil)
        hidePanel()
        if let monitor = globalClick { NSEvent.removeMonitor(monitor) }
        if let monitor = localClick { NSEvent.removeMonitor(monitor) }
        model.stop()
    }

    private func checkSmokeTest() {
        guard CommandLine.arguments.contains("--smoke-test"), !smokeStarted,
              model.snapshot.usageState == "live", model.snapshot.tasks.count != nil else { return }
        smokeStarted = true
        showPanel(pinned: false)
        hoverWatch?.invalidate() // Test the hover-open state without moving the user's pointer.
        let hoverSelectors = responds(to: NSSelectorFromString("mouseEntered:")) && responds(to: NSSelectorFromString("mouseExited:"))
        let hovered = panel?.isVisible == true && !isPinned && hoverSelectors
        togglePanel() // Clicking an already hover-open panel pins it instead of closing it.
        let pinned = panel?.isVisible == true && isPinned
        toggleDesktopFloating()
        let floating = model.desktopFloating && panel?.isVisible == true
        dismissTransientPanel()
        let survivesOutside = panel?.isVisible == true
        if let panel = panel {
            panel.setFrameOrigin(NSPoint(x: panel.frame.minX - 30, y: panel.frame.minY - 20))
        }
        let desktopPosition = panel?.frame.origin
        resizePanel() // Usage updates must not snap the floating window back to the menu bar.
        let retainsPosition = panel?.frame.origin == desktopPosition
        toggleDesktopFloating()
        let restored = !model.desktopFloating && panel?.isVisible == true
        presentSoundSelector(.lowUsage)
        let soundListOpened = soundPopover?.isShown == true
        presentSettings()
        let settingsOpened = settingsPopover?.isShown == true
        model.objectWillChange.send() // Selection publishes the same UI-update signal; the list must stay open.
        let previousClock = model.now
        let codexMenu = makeCodexMenu()
        let menuWired = codexMenu.items.filter { !$0.isSeparatorItem }.map(\.title) == ["打开 Codex", "退出 Codex"] &&
            codexMenu.items.first?.action == #selector(openMainApp) && codexMenu.items.last?.action == #selector(closeMainApp)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self = self, let panel = self.panel else { return }
            let size = panel.contentView?.bounds.size ?? .zero
            let settingsStaysOpen = self.settingsPopover?.isShown == true
            let clockTicks = self.model.now > previousClock
            let statusIconVisible = self.statusItem?.button?.image?.size == StatusQuotaIndicator.imageSize &&
                self.statusItem?.button?.imagePosition == .imageOnly && self.statusItem?.button?.title == "" &&
                self.statusItem?.length == StatusQuotaIndicator.itemLength
            self.settingsPopover?.performClose(nil)
            self.soundPopover?.performClose(nil)
            panel.cancelOperation(nil)
            self.writeSmokeResult(["passed": hovered && pinned && floating && survivesOutside && retainsPosition && restored && soundListOpened && settingsOpened && settingsStaysOpen && !panel.isVisible && size.width == 270 && size.height == 227 && clockTicks && menuWired && statusIconVisible,
                                   "hoverExpanded": hovered, "clickPinned": pinned,
                                   "desktopFloating": floating, "survivesOutsideClick": survivesOutside,
                                   "positionSurvivesRefresh": retainsPosition, "restoredToMenuBar": restored,
                                   "soundListOpened": soundListOpened, "settingsOpened": settingsOpened, "settingsStaysOpen": settingsStaysOpen,
                                   "escapeClosed": !panel.isVisible, "width": size.width, "height": size.height,
                                   "clockTicks": clockTicks, "codexMenuWired": menuWired, "statusIconVisible": statusIconVisible,
                                   "quotaLive": self.model.snapshot.usageState == "live"])
        }
    }

    private func writeSmokeResult(_ result: [String: Any]) {
        smokeTimeout?.invalidate()
        if let index = CommandLine.arguments.firstIndex(of: "--smoke-test"), CommandLine.arguments.count > index + 1,
           let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }
        NSApplication.shared.terminate(nil)
    }

    private func renderPreview(inputPath: String, outputPath: String) {
        do {
            if let index = CommandLine.arguments.firstIndex(of: "--transparency-preview"), CommandLine.arguments.count > index + 1,
               let value = Double(CommandLine.arguments[index + 1]) {
                model.backgroundTransparency = min(1, max(0, value))
            }
            if let index = CommandLine.arguments.firstIndex(of: "--time-preview"), CommandLine.arguments.count > index + 1,
               let date = ISO8601DateFormatter().date(from: CommandLine.arguments[index + 1]) { model.now = date }
            model.snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: URL(fileURLWithPath: inputPath)))
            if let index = CommandLine.arguments.firstIndex(of: "--weather-preview"), CommandLine.arguments.count > index + 1,
               let data = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index + 1])),
               let response = try? JSONDecoder().decode(WeatherResponse.self, from: data) {
                model.weather.reading = response.reading(now: Date().timeIntervalSince1970)
                model.weather.place = "天气演示"
            }
            let soundPreview = CommandLine.arguments.contains("--sound-preview")
            let content = soundPreview
                ? AnyView(SoundSelector(model: model, event: CommandLine.arguments.contains("--reset-sound") ? .resetDue : .lowUsage, onDone: {}, doneTitle: "返回设置"))
                : CommandLine.arguments.contains("--about-preview")
                ? AnyView(AboutView(model: model, onDone: {}))
                : CommandLine.arguments.contains("--settings-preview")
                    ? AnyView(SettingsView(model: model, onDone: {})) : AnyView(Dashboard(model: model))
            let host = NSHostingView(rootView: content)
            let size = host.fittingSize
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            previewWindow = window
            window.orderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                host.layoutSubtreeIfNeeded()
                if let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: image)
                    if let data = image.representation(using: .png, properties: [:]) {
                        try? data.write(to: URL(fileURLWithPath: outputPath))
                    }
                }
                NSApplication.shared.terminate(nil)
            }
        } catch {
            fputs("Preview failed: \(error)\n", stderr)
            NSApplication.shared.terminate(nil)
        }
    }
}

@main struct CodexMiniApplication {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
