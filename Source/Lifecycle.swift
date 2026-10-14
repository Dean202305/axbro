import AppKit
import Foundation

func argument(_ key: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: key), index + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[index + 1]
}

final class LifecycleWatcher {
    private let codexID: String
    private let miniID: String
    private let miniURL: URL
    private var wasRunning: Bool?
    private var observers: [NSObjectProtocol] = []
    private var poll: Timer?

    init(codexID: String, miniID: String, miniURL: URL) {
        self.codexID = codexID
        self.miniID = miniID
        self.miniURL = miniURL
    }

    private func running(_ identifier: String) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: identifier).filter { !$0.isTerminated }
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.reconcile()
            })
        }
        // The event stream is primary; a slow fallback covers crash termination or missed notifications.
        poll = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.reconcile() }
        reconcile()
    }

    private func report(_ event: String) {
        print(event)
        fflush(stdout)
    }

    private func reconcile() {
        let codexRunning = !running(codexID).isEmpty
        guard wasRunning != codexRunning else { return }
        wasRunning = codexRunning
        if codexRunning {
            guard running(miniID).isEmpty else { report("codex-running: mini-already-running"); return }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            NSWorkspace.shared.openApplication(at: miniURL, configuration: config) { [weak self] app, error in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if error != nil || app == nil {
                        self.wasRunning = nil // Retry on the next fallback pass.
                        self.report("mini-launch-failed")
                    } else if self.running(self.codexID).isEmpty {
                        app?.terminate() // Codex may have quit while launching the mini app.
                        self.report("mini-closed: codex-exited-during-launch")
                    } else {
                        self.report("mini-started-with-codex")
                    }
                }
            }
        } else {
            let applications = running(miniID)
            for app in applications { app.terminate() }
            report(applications.isEmpty ? "codex-not-running: mini-not-running" : "mini-closed-with-codexs")
        }
    }
}

@main struct LifecycleApplication {
    static func main() {
        let defaultApp = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/axbro.app")
        let watcher = LifecycleWatcher(codexID: argument("--codex-bundle-id") ?? "com.openai.codex",
                                       miniID: argument("--mini-bundle-id") ?? "local.dean.CodexMini",
                                       miniURL: URL(fileURLWithPath: argument("--mini-app") ?? defaultApp.path))
        NSApplication.shared.setActivationPolicy(.prohibited)
        watcher.start()
        withExtendedLifetime(watcher) { NSApplication.shared.run() }
    }
}
